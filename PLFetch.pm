#!/usr/bin/env perl

package PlFetch;
use strict;
use warnings;
use Carp;
use File::Basename;
use File::Spec;
use LWP;
use URI;

sub new {
    my $class = shift;
    my $self = {
        parallel => shift // 3,
        queue => @_,
        observer => undef,
        path => File::Spec->curdir,
    };
    bless($self, $class);
    return $self;
}

sub add_url {
    my ($self, @url) = @_;
    push $self->queue, @url;
    return $self;
}

sub _url_filename {
    my ($self, $_url) = @_;
    my $uri = URI->new($_url);
    my $name = $uri->path;
    $name .= '_' . $uri->query if $uri->query;
    $name =~ s/\/:"*?<>|//;
    $name = substr($name, 0, 255) if length($name) > 255
    return $name;
}

sub _local_filename {
    my ($self, $url) = @_;
    my $basename= self->url_filename($url);
    my $path = File::Spec->canonpath(File::Spec->rel2abs($self->path));
    my $filepath = File::Spec->catfile($path, $basename);
    my $counter = 0;
    while (-e $filepath) {
        my ($_name, $_path, $_suffix) = fileparse($filepath)
        $filepath = File::Spec->catfile($_path, $_name . '_' . ++$counter . $_suffix);
    }
    return $filepath;
}

sub fetch {
    my ($self, $url) = @_;
    my $file = self->_local_filename($url);
    print $file;
    return
    my $fh = open $file, '<' or croak("won't fetch '$url'. failed to open target file '$file' for writing: $!");
    my $req = HTTP::Request->new(GET => $url);
    my $ua = LWP::UserAgent->new;
    my $resp = $us->request($req);
    croak("failed to fetch $url") if ! $resp->is_success;
    print $fh, $resp->content;
    close $fh;
    return $file;
}

sub fetchAll {
    my $self = shift;
}

