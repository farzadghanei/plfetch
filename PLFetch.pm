#!/usr/bin/env perl

package PlFetch;
use strict;
use warnings;
use Carp;
use File::Basename;
use File::Spec;
use LWP;
use URI;
use Data::Dumper;

sub new {
    my $class = shift;
    my $self = {
        parallel => 3,
        observer => 0,
        path => '.',
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
    confess("invalid filename '$name'");
    my $path = File::Spec->canonpath(File::Spec->rel2abs($self->{path}));
    my $filepath = File::Spec->catfile($path, $basename);
    my $counter = 0;
    while (-e $filepath) {
        my ($_name, $_path, $_suffix) = fileparse($filepath);
        $filepath = File::Spec->catfile($_path, $_name . '_' . ++$counter . $_suffix);
    }
    return $filepath;
}

sub _http_url_info {
    my ($self, $url) = @_;
    my $info = {
        name => undef,
        size => undef,
    };
    my $req = HTTP::Request->new(HEAD => $url);
    my $ua = LWP::UserAgent->new;
    my $resp = $ua->request($req);
    my $headers = $resp->headers;
    $info->{size} = $headers->{'content-length'} // undef;
    if (exists $headers->{'content-disposition'}) {
        # Content-Disposition: attachment; filename="fname.ext"
        if ($headers->{'content-disposition'} ~= /attachment;\s*filename\s*=\s*"(.*)"/) {
            $info->{name} = $1;
        }
    }
    return $info;
}

sub _fetch_https {
    my ($self, $url, $file) = @_;
    return $self->_fetch_http($url, $file);
}

sub _fetch_http {
    my ($self, $url, $file) = @_;
    my $info = $self->_http_url_info($url);
    if (!$file) {
        $file = $info->{name} // $self->_filename_from_url($url);
    }
    $file = $self->_make_local_filename($file);
    my $fh;
    open $fh, '>', $file or croak("won't fetch '$url'. failed to open target file '$file' for writing: $!");
    my $req = HTTP::Request->new(GET => $url);
    my $ua = LWP::UserAgent->new;
    my $resp = $ua->request($req);
    croak("failed to fetch '$url'") if ! $resp->is_success;
    print $fh $resp->content;
    close $fh;
    return $file;
}

sub fetch {
    my ($self, $url, $file) = @_;
    my $_uri = URI->new($url);
    my $handler = "_fetch_" . $_uri->scheme;
    return $self->$handler($url) if $self->can($handler, $file);
    if (!$file) {
        $file = $self->_filename_from_url($url);
    }
    $file = $self->_make_local_filename($file);
    my $fh;
    open $fh, '>', $file or croak("won't fetch '$url'. failed to open target file '$file' for writing: $!");
    my $req = HTTP::Request->new(GET => $url);
    my $ua = LWP::UserAgent->new;
    my $resp = $ua->request($req);
    croak("failed to fetch $url") if ! $resp->is_success;
    print $fh, $resp->content;
    close $fh;
    return $file;
}

sub fetchAll {
    my $self = shift;
}

__PACKAGE__->run( @ARGV ) unless caller;

sub run {
    my ($class, @args) = @_;
    my $fetcher = $class->new();
    $fetcher->fetch($args[0]);
    return 0;
}

1;
