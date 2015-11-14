use strict;
use warnings;
use Test::Clustericious::Config;
use Test::More tests => 5;
use App::clad;
use File::HomeDir;
use Path::Class qw( file );
use Clustericious::Config;
use Capture::Tiny qw( capture );

my $dist_root = file( __FILE__)->parent->parent->absolute;

note "dist_root = $dist_root";

create_config_ok Clad => {
  env => {},
  clusters => {
    cluster1 => [ qw( host1 host2 host3 ) ],
    cluster2 => [ qw( host4 host5 host6 ) ],
  },
  server_command => 
    "$^X @{[ $dist_root->file('corpus', 'fake-server.pl') ]} --server",
  ssh_command =>
    [ $^X, $dist_root->file('corpus', 'fake-ssh.pl')->stringify ],
  ssh_options =>
    [ -o => "Foo=yes", -o => "Bar=no" ],
};

subtest basic => sub {
  plan tests => 7;

  my($out, $err, $exit) = capture {
    App::clad->new(
      'cluster1', 
      '--', 
      $^X, -E => 'say "host=$ENV{CLAD_HOST}"; say "cluster=$ENV{CLAD_CLUSTER}"',
    )->run;
  };
  
  is $exit, 0, 'exit = 0';
  my %out = map { $_ => 1 }split /\n/, $out;
  
  for(1..3)
  {
    ok $out{"[host$_ out ] cluster=cluster1"}, "host $_ cluster 1";
    ok $out{"[host$_ out ] host=host$_"},      "host $_ host $_";
  }
  
};

subtest 'with specified user' => sub {
  plan tests => 4;

  my($out, $err, $exit) = capture {
    App::clad->new(
      -l => 'foo',
      'cluster1', 
      '--',
      $^X, -E => 'say "user=$ENV{USER}"',
    )->run;
  };
  
  is $exit, 0, 'exit = 0';
  
  my %out = map { $_ => 1 }split /\n/, $out;
  
  for(1..3)
  {
    ok $out{"[foo\@host$_ out ] user=foo"}, "host $_";
  }
};

subtest 'with two users' => sub {
  plan tests => 7;

  my($out, $err, $exit) = capture {
    App::clad->new(
      'foo@cluster1,bar@cluster2', 
      '--',
      $^X, -E => 'say "user=$ENV{USER}"',
    )->run;
  };

  is $exit, 0, 'exit = 0';
  my %out = map { $_ => 1 }split /\n/, $out;

  for(1..3)
  {
    ok $out{"[foo\@host$_ out ] user=foo"}, "host $_";
  }
  for(4..6)
  {
    ok $out{"[bar\@host$_ out ] user=bar"}, "host $_";
  }
};

subtest 'failure' => sub {

  my($out, $err, $exit) = capture {
    App::clad->new(
      'cluster1',
      '--',
      $^X, -E => 'exit 22',
    )->run;
  };
  
  is $exit, 2, 'exit = 2';
  
  my %out = map { $_ => 1 }split /\n/, $out;

  for(1..3)
  {
    ok $out{"[host$_ exit] 22"}, "host $_";
  }

};