#!/usr/bin/env perl

# The MIT License (MIT)
# Copyright (c) 2013 Farzad Ghanei
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

package PLFetch;

my $VERSION = "0.1.7";

use strict;
use warnings;
use Carp;
use File::Basename;
use File::Spec;
use LWP 5.64;
use URI;
use Time::HiRes qw(sleep time);
use threads;

sub new {
    my $class = shift;
    my $self = {
        quiet => undef,
        debug => undef,
        parallel => 3,
        path => '.',
        url_info_cache => {},
        refresh_rate => 0.5,
    };
    $self->{queu} = qw();
    bless $self, $class;
    return $self;
}

sub add_url {
    my ($self, @url) = @_;
    push $self->queue, @url;
    return $self;
}

sub _debug {
    my ($self, @msg) = @_;
    if ($self->{debug}) {
        $self->_print(@msg);
        $self->_print("\n");
    }
    return $self;
}

sub _clear_output_line {
    my $self = shift;
    $self->_print("\r \b");
    return $self;
}

sub _is_on_tty {
    return -t STDOUT;
}

sub _print {
    my ($self, @msg) = @_;
    return if $self->{quiet};
    if (-t STDOUT) {
        print(@msg);
    }
    return $self;
}

sub _filename_from_url {
    my ($self, $url) = @_;
    my $_uri = URI->new($url);
    my $name = $_uri->path;
    if ($name and substr($name, 0, 1) = '/') {
        $name = substr($name, 1);
    }
    if ($name) {
        $name = basename($name);
    } else {
        $name = $_uri->host;
    }
    $name .= '_' . $_uri->query if $_uri->query;
    return $name;
}

sub _cleanup_filename {
    my ($self, $name) = @_;
    return $name if !$name;
    $name =~ s/[\\'"\*\?\:\/&]/_/g;
    $name = substr($name, 0, 128) if length($name) > 128;
    return $name;
}

sub _make_local_filename {
    my ($self, $name) = @_;
    my $basename = $self->_cleanup_filename($name);
    confess("invalid filename '$name'") if ! $basename;
    my $path = File::Spec->canonpath(File::Spec->rel2abs($self->{path}));
    my $filepath = File::Spec->catfile($path, $basename);
    my $counter = 0;
    while (-e $filepath) {
        my ($_name, $_path, $_suffix) = fileparse($filepath);
        $filepath = File::Spec->catfile($_path, $_name . '_' . ++$counter . $_suffix);
    }
    return $filepath;
}

sub _url_info_http {
    my ($self, $url) = @_;
    my $info = {
        filename => undef,
        total => undef,
    };
    my $req = HTTP::Request->new(HEAD => $url);
    my $ua = LWP::UserAgent->new;
    my $resp = $ua->request($req);
    my $headers = $resp->headers;
    $info->{total} = $headers->{'content-length'} // undef;
    if (exists $headers->{'content-disposition'}) {
        # Content-Disposition: attachment; filename="fname.ext"
        if ($headers->{'content-disposition'} =~ /attachment;\s*filename\s*=\s*"(.*)"/) {
            $info->{filename} = $1;
        }
    }
    return $info;
}

sub _url_info {
    my ($self, $url, $refresh) = @_;
    confess("no URL speicifed") if !$url;
    if ($refresh || !exists $self->{url_info_cache}->{$url}) {
        my $_uri = URI->new($url);
        my $scheme = $_uri->scheme;
        my $scheme_info_sub = "_url_info_$scheme";
        my $info = {
            filename => undef,
            total => undef,
            scheme => $scheme,
            path => $_uri->path,
            host => $_uri->host,
            port => ($_uri->port // $_uri->default_port),
        };
        if ($self->can($scheme_info_sub)) {
            my $scheme_info = $self->$scheme_info_sub($url);
            foreach (keys %$scheme_info) {
                $info->{$_} = $scheme_info->{$_};
            }
        }
        $self->{url_info_cache}->{$url} = $info;
    }
    return $self->{url_info_cache}->{$url};
}

sub _fetch_https {
    my ($self, $url, $file) = @_;
    return $self->_fetch_http($url, $file);
}

sub _fetch_http {
    my ($self, $url, $file) = @_;
    if (!$file) {
        my $info = $self->_url_info($url);
        $file = $info->{filename} // $self->_filename_from_url($url);
        $file = $self->_make_local_filename($file);
    }
    my $fh;
    open $fh, '>', $file or croak("won't fetch '$url'. failed to open target file '$file' for writing: $!");
    close $fh;
    my $ua = LWP::UserAgent->new;
    my $resp = $ua->get($url, ':content_file' => $file);
    if (!$resp->is_success) {
        close $fh;
        die("failed to fetch '$url'");
    }
    return $file;
}

sub _fetch {
    my ($self, $url, $file) = @_;
    my $info = $self->_url_info($url);
    my $handler = "_fetch_" . $info->{scheme};
    return $self->$handler($url, $file) if $self->can($handler);

    if (!$file) {
        $file = $info->{filename} // $self->_filename_from_url($url);
        $file = $self->_make_local_filename($file);
    }

    my $fh;
    open $fh, '>', $file or croak("won't fetch '$url'. failed to open target file '$file' for writing: $!");
    close $fh;
    my $ua = LWP::UserAgent->new;
    my $resp = $ua->get($url, ':content_file' => $file);
    if (!$resp->is_success) {
        close $fh;
        die("failed to fetch $url");
    }
    return $file;
}

sub _progressbar {
    my ($self, $start, $size, $total, $counter, $max_width) = @_;
    $start //= 0;
    $size //= 0;
    $total //= 0;
    $counter //= 0;
    $max_width //= 30;
    my @buff;
    if ($total) {
        my $ratio = $size / $total;
        $counter = int($max_width * $ratio);
        push @buff, sprintf('% 2.2f%% ', 100 * $ratio);
        push @buff, ('[' . ('#' x $counter) . ('-' x ($max_width - $counter)) . ']');
    } else {
        push @buff, ( '--.--% ' );
        push @buff, ('[' . ('-' x $counter) . '#' . ('-' x ($max_width - $counter)) . ']');
    }

    push @buff, (
        sprintf(
            "%6dKB %3.2fKBs %4.2fs",
            ($size / 1024),
            ($size / 1024 / (time - $start)),
            time - $start,
        )
    );
    return join('', @buff);
}

sub _counting_progressbar {
    my ($self, $start, $size, $total, $counter, $max_width) = @_;
    $start //= 0;
    $size //= 0;
    $total //= 0;
    $counter //= 0;
    $max_width //= 30;
    my @buff;
    if ($total) {
        my $ratio = $size / $total;
        $counter = int($max_width * $ratio);
        push @buff, sprintf('% 3d/%d ', $size, $total);
        push @buff, ('[' . ('#' x $counter) . ('-' x ($max_width - $counter)) . ']');
    } else {
        push @buff, ( '--.--% ' );
        push @buff, ('[' . ('-' x $counter) . '#' . ('-' x ($max_width - $counter)) . ']');
    }

    push @buff, sprintf(" %4.2fs", time - $start);
    return join('', @buff);
}

sub fetch {
    my ($self, $url, $file) = @_;
    confess("no URL specified!") if !$url;
    my $info = $self->_url_info($url);
    if (!$file) {
        $file = $info->{filename} // $self->_filename_from_url($url);
    }
    $file = $self->_make_local_filename($file);

    $self->_debug('starting worker thread ...');
    my $worker_thread = threads->create( sub { $self->_fetch($url, $file) } );
    $self->_debug("worker thread '$worker_thread' started");
    my $refresh_rate = $self->{refresh_rate} // 0.5;
    my $start = time;
    my $max_width = 30;
    my $last_size_check = time;

    # progress
    my $counter = 1;
    my $total = $info->{total} // 0;
    while (1) {
        my $size = 0;
        if (!-f $file || !-s $file) {
            if (time - $last_size_check > 60) {
                croak("failed to fetch '$url'. timedout!");
            }
        } else {
            $last_size_check = time;
            $size = -s $file // 0;
        }

        if ($self->_is_on_tty) {
            $self->_print( $self->_progressbar($start, $size, $total, $counter, $max_width) );
        }

        sleep($refresh_rate);

        if ($self->_is_on_tty) {
            $self->_clear_output_line();
        }

        $counter = 1 if ++$counter > $max_width;

        my $is_running = $worker_thread->is_running;
        $size = -s $file;
        if (($size < $total) && !$is_running) {
            $self->_print("\n");
            $worker_thread->join if $worker_thread->is_joinable;
            croak("failed to fetch '$url'. worker thread exited unexpectedly!");
        } elsif ( ($total && $size >= $total) || !$is_running ) {
            if ($self->_is_on_tty) {
                $self->_print( $self->_make_progressbar($start, $size, $total, $counter, $max_width) );
            }
            last;
        }
    }
    $worker_thread->join if $worker_thread->is_joinable;
    $self->_print("\nfetched '$url' to '$file'\n");
    return $file;
}

sub fetchAll {
    my ($self, @urls) = @_;
    confess("no URL specified!") if scalar @urls < 1;

    my $refresh_rate = $self->{refresh_rate} // 0.5;
    my $max_width = 30;
    my $qsize = $self->{parallel} // scalar @urls;

    my $threads = {};
    my $errors = {};
    my @finished;
    my @running;

    my $info = {};
    foreach (@urls) {
        my $i = $self->_url_info($_);
        if (!$i->{filename}) {
            $i->{filename} = $self->_filename_from_url($_);
        }
        my $filename = $i->{filename};
        $i->{localfile} = $self->_make_local_filename($filename);
        $info->{$_} = $i;
        $info->{$_}->{total} = $i->{total} // 0;
        $info->{$_}->{size} = 0;
        $info->{$_}->{display} = length($filename) < ($max_width - 10) ? $filename : substr($filename, 0, $max_width - 10) . '...';
    }

    foreach (@urls) {
        $self->_debug("starting worker thread to fetch '$_'");
        $threads->{$_} = threads->create( sub { $self->_fetch($_, $info->{$_}->{localfile}) } );
        $self->_debug("started thread '$threads->{$_}' to fetch '$_'");
        $info->{$_}->{start} = time;
        $info->{$_}->{last_size_check} = time;
    }


    # progress
    my $counter = 1;
    while (1) {
        foreach (@urls) {
            next if exists $errors->{$_} or exists $finished->{$_};
            my $i = $info->{$_};
            my $file = $i->{localfile};
            if (!-f $file || !-s $file) {
                if (time - $i->{last_size_check} > 60) {
                    my $msg = "failed to fetch '$i->{display}'. timedout!";
                    $errors->{$_} = $msg;
                }
            } else {
                $info->{$_}->{last_size_check} = time;
                $info->{$_}->{size} = -s $file // 0;
            }
        }

        foreach (@urls) {
            my $i = $info->{$_};
            $self->_print($i->{display} . "\n");
            if (exists $errors->{$_}) {
                $self->_print($errors->{$_});
            }
            elsif (exists $finished->{$_}) {
                my $fake_start = $i->{start} + (time - $finished->{$_});
                $self->_print( $self->_make_progressbar($fake_start, $i->{size}, $i->{total}, $max_width, $max_width) );
            }
            else {
                $self->_print( $self->_make_progressbar($i->{start}, $i->{size}, $i->{total}, $counter, $max_width) );
            }
            $self->_print("\n");
        }

        sleep($refresh_rate);

        $self->_clear_output_lines(2 * (scalar @urls));
        $counter = 1 if ++$counter > $max_width;

        foreach (@urls) {
            next if (exists $errors->{$_} or exists $finished->{$_});
            my $i = $info->{$_};
            my $file = $i->{localfile};
            if (!-f $file) {
                $errors->{$_} = "local file '$file' is missing. fetching '$i->{display}' failed!";
                next;
            }
            my $size = -s $file // 0;
            $info->{$_}->{size} = $size;
            my $total = $i->{total};
            my $worker_thread = $threads->{$_};
            my $is_running = $worker_thread->is_running;
            if (($size < $total) && !$is_running) {
                $worker_thread->join if $worker_thread->is_joinable;
                $errors->{$_} = "failed to fetch '$i->{display}'. worker thread exited unexpectedly!";
            } elsif ( ($total && $size >= $total) || !$is_running ) {
                $finished->{$_} = time;
            }
        }
        last if (scalar keys %$finished >= scalar @urls);
    } # while (1)

    foreach (keys $errors) {
        $self->_print("failed to fetch '$_': " . $errors->{$_} . "\n");
    }

    foreach (keys $finished) {
        $self->_print("fetched '$_' to '" . $info->{$_}->{localfile} . "'\n");
    }

    foreach (keys $threads) {
        my $worker_thread = $threads->{$_};
        $self->_debug("joining thread '$worker_thread' responsible for '$_'.");
        $worker_thread->join if $worker_thread->is_joinable;
    }

    return [$finished, $errors];
}

my $_usage = <<endofusage;
PLFetch v${VERSION}
usage:
$0 [options] URL [URL2] [...]
options:
    -h, --help      show this help
    -q, --queit     do not output progress
    -d, --debug     output debugging information
    -o, --output    name of the output file (in multiple
                    downloads, the path to save files).
    -p, --parallel  concurrent downloads (default is 1)
endofusage

__PACKAGE__->run( @ARGV ) unless caller;

sub run {
    my ($class, @args) = @_;
    use Getopt::Long qw(GetOptionsFromArray);

    local $| = 1;
    my $help = undef;
    my $quiet = undef;
    my $debug = undef;
    my $output = undef;
    my $parallel = 1;

    GetOptionsFromArray(\@args,
        "help|h" => \$help,
        "output|o=s" => \$output,
        "quiet|q" => \$quiet,
        "debug|d" => \$debug,
        "parallel|p=i" => \$parallel,
    );

    if ($help) {
        print $_usage;
        exit(64);
    }

    my $total = scalar @args;
    if (!$total) {
        print STDERR "please specify a URL. use -h or --help for more info";
        exit(65);
    }

    $quiet = undef if $debug;
    my $fetcher = $class->new;
    $fetcher->{quiet} = $quiet if $quiet;
    $fetcher->{debug} = $debug if $debug;
    $fetcher->{parallel} = $parallel if $parallel > 1;

    if ($total == 1) {
        if ($output && -d $output) {
            $fetcher->{path} = $output;
            $output = undef;
        }
        $fetcher->fetch($args[0], $output);
    } else {
        if ($output && !-d $output) {
            $fetcher->{path} = dirname($output);
        }
        $fetcher->fetchAll(@args);
    }
    return 0;
}

1;
