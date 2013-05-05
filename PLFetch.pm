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

my $VERSION = "0.2.0";

use strict;
use warnings;
use List::Util qw(min);
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
    bless $self, $class;
    return $self;
}

sub _debug {
    my ($self, @msg) = @_;
    if ($self->{debug}) {
        $self->_clear_output_line;
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

sub fetch {
    my ($self, $url, $file) = @_;
    confess("no URL specified!") if !$url;
    my $info = $self->_url_info($url);
    $file ||= $info->{filename} // $self->_filename_from_url($url);
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
            $self->_clear_output_line;
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
                $self->_print( $self->_progressbar($start, $size, $total, $counter, $max_width) );
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

    my $threads = {};
    my $errors = {};
    my $finished = {};
    my $running = {};
    my $info = {};

    # making sure for unique URLs and fast access to all
    my $all = {};
    foreach (@urls) {
        $all->{$_} = 1;
    }
    my @todo = keys %$all;
    my $num_all = scalar @todo;

    my $qsize = min($self->{parallel}, $num_all);
    my $start = time;
    while (1) {
        while (scalar @todo && $qsize > scalar keys %$running) {
            my $url = shift @todo;
            $self->_debug("adding '$url' to running queue");
            $info->{$url} = $self->_url_info($url);
            $info->{$url}->{total} //= 0;
            $info->{$url}->{filename} //= $self->_filename_from_url($url);
            my $filename = $info->{$url}->{filename};
            $info->{$url}->{localfile} = $self->_make_local_filename($filename);
            $info->{$url}->{size} = 0;

            $threads->{$url} = threads->create( sub { $self->_fetch($url, $info->{$url}->{localfile}) } );
            $info->{$url}->{start} = time;
            $info->{$url}->{first_size_check} = undef;
            $info->{$url}->{last_size_check} = undef;
            $running->{$url} = time;
        }

        foreach (keys %$running) {
            $self->_debug("checking running task: '$_' ...");
            if (exists $errors->{$_} or exists $finished->{$_}) {
                $self->_debug("'$_' is still in running queue but should not. weird!");
                delete $running->{$_};
                next;
            }
            my $i = $info->{$_};
            my $file = $i->{localfile};
            my $size;
            my $total = $i->{total};

            if (!-f $file || !($size = -s $file)) {
                $self->_debug("local file '$file' does not exist!");
                if ($i->{last_size_check} && time - $i->{last_size_check} > 60) {
                    $errors->{$_} = "failed to fetch '$_'. timedout!";
                    $self->_debug("failed to fetch '$_'. timedout!");
                    delete $running->{$_};
                } elsif ($i->{first_size_check} && $i->{size} < $i->{total}) {
                    $errors->{$_} = "failed to fetch '$_'. local file '$file' is missing!";
                    $self->_debug("failed to fetch '$_'. local file '$file' is missing!");
                    delete $running->{$_};
                }
                next;
            }

            $info->{$_}->{first_size_check} //= time;
            $info->{$_}->{last_size_check} = time;
            $info->{$_}->{size} = $size // 0;

            my $th = $threads->{$_};
            my $is_running = $th->is_running;
            if (($size < $total) && !$is_running) {
                $errors->{$_} = "failed to fetch '$_'. worker thread exited unexpectedly!";
                $self->_debug("failed to fetch '$_'. worker thread exited unexpectedly!");
                delete $running->{$_};
            } elsif ( ($total && $size >= $total) || !$is_running ) {
                $self->_debug("fetchign '$_' is finished!");
                $finished->{$_} = time;
                delete $running->{$_};
            }
        } # foreach (keys %running ...

        if ($self->_is_on_tty) {
            my $progress = sprintf('[%.2fs] total: %d - active: %d - finished: %d - errors: %d',
                    time - $start,
                    scalar $num_all,
                    scalar keys %$running,
                    scalar keys %$finished,
                    scalar keys %$errors,
                );
            $self->_clear_output_line;
            if ($self->{debug}) {
                $self->_debug($progress);
            } else {
                $self->_print($progress);
            }
        }

        last if ( $num_all <= ((scalar keys %$finished) + (scalar keys %$errors)) );
        sleep($refresh_rate);
    } # while

    foreach (keys %$all) {
        my $th = $threads->{$_} || undef;
        if ($th) {
            $self->_debug("joining thread '$th' responsible for '$_'.");
            $th->join if $th->is_joinable;
        }
    }

    $self->_print("\n") if $self->_is_on_tty;
    foreach (keys %$errors) {
        $self->_print("failed to fetch '$_': " . $errors->{$_} . "\n");
    }

    foreach (keys %$finished) {
        $self->_print("fetched '$_' to '" . $info->{$_}->{localfile} . "'\n");
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
        print STDERR "please specify a URL. use -h or --help for more info\n";
        exit(65);
    }

    $quiet = undef if $debug;
    my $fetcher = $class->new;
    $fetcher->{quiet} = $quiet if $quiet;
    $fetcher->{debug} = $debug if $debug;
    $fetcher->{parallel} = $parallel if $parallel > 0;
    if ($output) {
        if (-d $output) {
            $fetcher->{path} = $output;
            $output = undef;
        } else {
            my $output_dir = dirname($output) || undef;
            $output = basename($output) || undef;
            $fetcher->{path} = $output_dir;
        }
    }

    if ($total == 1) {
        $fetcher->fetch($args[0], $output);
    } else {
        $fetcher->fetchAll(@args);
    }
    return 0;
}

1;
