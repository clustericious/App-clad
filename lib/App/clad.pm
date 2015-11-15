package App::clad;

use strict;
use warnings;
use 5.010;
use Getopt::Long qw( GetOptions );
use Pod::Usage qw( pod2usage );
use Clustericious::Config 1.03;
use YAML::XS qw( Dump Load );
use Term::ANSIColor ();
use Sys::Hostname qw( hostname );

# ABSTRACT: Parallel SSH client
# VERSION

=head1 SYNOPSIS

 % perldoc clad

=head1 DESCRIPTION

This module provides the implementation for the L<clad> command.  See 
the L<clad> command for the public interface.

=head1 SEE ALSO

=over 4

=item L<clad>

=back

=cut

sub main
{
  my $clad = shift->new(@_);
  $clad->run;
}

# this hook is used for testing
# see t/args.t subtest 'color'
our $_stdout_is_terminal = sub { -t STDOUT };

sub new
{
  my $class = shift;

  my $self = bless {
    dry_run    => 0,
    color      => $_stdout_is_terminal->(),
    server     => 0,
    verbose    => 0,
    serial     => 0,
    next_color => -1,
    ret        => 0,
  }, $class;
  
  local @ARGV = @_;
  
  my $config_name = 'Clad';
  
  GetOptions(
    'n'        => \$self->{dry_run},
    'a'        => sub { $self->{color} = 0 },
    'l=s'      => \$self->{user},
    'server'   => \$self->{server},
    'verbose'  => \$self->{verbose},
    'serial'   => \$self->{serial},
    'config=s' => \$config_name,
    'help|h'   => sub { pod2usage({ -verbose => 2}) },
    'version'  => sub {
      say STDERR 'App::clad version ', ($App::clad::VERSION // 'dev');
      exit 1;
    },
  ) || pod2usage(1);
  
  $self->{config} = Clustericious::Config->new($config_name);
  
  return $self if $self->server;
  
  pod2usage(1) unless @ARGV >= 2;
  
  $self->{clusters} = [ split ',', shift @ARGV ];
  $self->{command}  = [ @ARGV ];

  if(my $expanded = $self->alias->{$self->command->[0]})
  {
    if(ref $expanded)
    {
      splice @{ $self->command }, 0, 1, @$expanded;
    }
    else
    {
      $self->command->[0] = $expanded;
    }
  }
  
  my $ok = 1;
  
  foreach my $cluster (map { "$_" } $self->clusters)
  {
    $cluster =~ s/^.*@//;
    unless($self->cluster_list->{$cluster})
    {
      say STDERR "unknown cluster: $cluster";
      $ok = 0;
    }
  }
  
  exit 2 unless $ok;
  
  $self;
}

sub config         { shift->{config}        }
sub dry_run        { shift->{dry_run}       }
sub color          { shift->{color}         }
sub clusters       { @{ shift->{clusters} } }
sub command        { shift->{command}       }
sub user           { shift->{user}          }
sub server         { shift->{server}        }
sub verbose        { shift->{verbose}       }
sub serial         { shift->{serial}        }
sub server_command { shift->config->server_command( default => 'clad --server' ) }
sub ssh_command    { shift->config->ssh_command(    default => 'ssh' ) }
sub ssh_options    { shift->config->ssh_options(    default => [ -o => 'StrictHostKeyChecking=no', 
                                                                 -o => 'BatchMode=yes',
                                                                 -o => 'PasswordAuthentication=no',
                                                                 '-T', ] ) }
sub ssh_extra      { shift->config->ssh_extra(      default => [] ) }

sub alias
{
  my($self) = @_;
  $self->config->alias( default => sub {
    my %deprecated = $self->config->aliases( default => {} );
    say STDERR "use of aliases key in configuration is deprecated, use alias instead"
        if %deprecated;
    \%deprecated;
  });
}

sub cluster_list
{
  my($self) = @_;
  $self->config->cluster( default => sub {
    my %deprecated = $self->config->clusters( default => {} );
    say STDERR "use of clusters key in configuration is deprecated, use cluster instead"
        if %deprecated;
    \%deprecated;
  });
}

sub ret
{
  my($self, $new) = @_;
  $self->{ret} = $new if defined $new;
  $self->{ret};
}

sub host_length
{
  my($self) = @_;

  unless($self->{host_length})
  {
    my $length = 0;
  
    foreach my $cluster (map { "$_" } $self->clusters)
    {
      my $user = $cluster =~ s/^(.*)@// ? $1 : $self->user;
      foreach my $host (@{ $self->cluster_list->{$cluster} })
      {
        my $prefix = ($user ? "$user\@" : '') . $host;
        $length = length $prefix if length $prefix > $length;
      }
    }
    
    $self->{host_length} = $length;
  }
  
  $self->{host_length};
}

sub next_color
{
  my($self) = @_;
  my @colors = $self->config->colors( default => ['green','cyan'] );
  $colors[ ++$self->{next_color} ] // $colors[ $self->{next_color} = 0 ];
}

sub run
{
  my($self) = @_;
  
  return $self->run_server if $self->server;
  
  my $ret = 0;
  my @done;
  
  foreach my $cluster (map { "$_" } $self->clusters)
  {
    my $user = $cluster =~ s/^(.*)@// ? $1 : $self->user;

    my %env = $self->config->env;
    $env{CLUSTER}      //= $cluster; # deprecate
    $env{CLAD_CLUSTER} //= $cluster;

    foreach my $host (@{ $self->cluster_list->{$cluster} })
    {
      my $prefix = ($user ? "$user\@" : '') . $host;
      if($self->dry_run)
      {
        say "$prefix % @{ $self->command }";
      }
      else
      {
        my $remote = Clustericious::Admin::RemoteHandler->new(
          prefix => $prefix,
          clad   => $self,
          env    => \%env,
          user   => $user,
          host   => $host,
        );

        my $done = $remote->cv;
        
        $self->serial ? $done->recv : push @done, $done;
      }
    }
  }
  
  $_->recv for @done;
  
  $self->ret;
}

sub run_server
{
  my($self) = @_;
  
  # Payload:
  #
  #   command: required, must be a array with at least one element
  #     the command to execute
  #
  #   env: optional, must be a hash reference
  #     any environmental overrides
  #
  #   verbose: optional true/false
  #     print out extra diagnostics
  #
  #   version: required number or 'dev'
  #     the client version
  #
  #   require: optional, number or 'dev'
  #     specifies the minimum required server
  #     server should die if requirement isn't met
  #     ignored if set to 'dev'
  #
  
  my $raw = do { local $/; <STDIN> };
  my $input = eval { Load($raw) };
  
  if(my $yaml_error = $@)
  {
    say STDERR "Clad Server: side YAML Error:";
    say STDERR $yaml_error;
    say STDERR "payload:";
    say STDERR $raw;
    return 2;
  }
  
  print STDERR Dump($input) if $input->{verbose};

  if(ref $input->{command} ne 'ARRAY' || @{ $input->{command} } == 0)
  {
    say STDERR "Clad Server: Unable to find command";
    return 2;
  }
  
  if(defined $input->{env} && ref $input->{env} ne 'HASH')
  {
    say STDERR "Clad Server: env is not hash";
    return 2;
  }
  
  unless($input->{version})
  {
    say STDERR "Clad Server: no client version";
    return 2;
  }
  
  if($input->{require} && defined $App::clad::VERSION)
  {
    if($input->{require} ne 'dev' && $input->{require} > $App::clad::VERSION)
    {
      say STDERR "Clad Server: client requested version @{[ $input->{require} ]} but this is only $App::clad::VERSION";
      return 2;
    }
  }
  
  $ENV{$_} = $input->{env}->{$_} for keys %{ $input->{env} };
  
  system @{ $input->{command} };
  
  if($? == -1)
  {
    say STDERR "Clad Server: failed to execute on @{[ hostname ]}";
    return 2;
  }
  elsif($? & 127)
  {
    say STDERR "Clad Server: died with signal @{[ $? & 127 ]} on @{[ hostname ]}";
    return 2;
  }
  
  return $? >> 8;
}

package Clustericious::Admin::RemoteHandler;

use strict;
use warnings;
use AE;
use AnyEvent::Open3::Simple 0.76;
use YAML::XS qw( Dump );

# VERSION

sub new
{
  my($class, %args) = @_;
  
  # args: prefix, clad, env, user, host
  
  my $self = bless {
    prefix => $args{prefix},
    clad   => $args{clad},
    cv     => AE::cv,
  }, $class;
  
  my $clad = $args{clad};
  
  my $done = $self->{cv};
  
  my $ipc = AnyEvent::Open3::Simple->new(
    on_start => sub {
      my($proc, $program, @args) = @_;
      $self->print_line(star => "% $program @args") if $clad->verbose;
    },
    on_stdout => sub {
      my($proc, $line) = @_;
      $self->print_line(out => $line);
    },
    on_stderr => sub {
      my($proc, $line) = @_;
      $self->print_line(err => $line);
    },
    on_exit => sub {
      my($proc, $exit, $signal) = @_;
      $self->print_line(exit => $exit) if $exit;
      $self->print_line(sig  => $signal) if $signal;
      $clad->ret(2) if $exit || $signal;
      $done->send;
    },
    on_error => sub {
      my($error) = @_;
      $self->print_line(fail => $error);
      $clad->ret(2);
      $done->send;
    },
  );
  
  my $payload = Dump({
    env     => $args{env},
    command => $clad->command,
    verbose => $clad->verbose,
    version => $App::clad::VERSION // 'dev',
  });
  
  $ipc->run(
    $clad->ssh_command,
    $clad->ssh_options,
    $clad->ssh_extra,
    ($args{user} ? ('-l' => $args{user}) : ()),
    $args{host},
    $clad->server_command,
    \$payload,
  );
  
  $self;
}

sub clad   { shift->{clad} }
sub prefix { shift->{prefix} }

sub color
{
  my($self) = @_;
  $self->{color} //= $self->clad->next_color;
}

sub is_color
{
  my($self) = @_;
  $self->{is_color} //= $self->clad->color;
}

sub print_line
{
  my($self, $code, $line) = @_;
  
  print Term::ANSIColor::color($self->color) if $self->is_color;
  $DB::single = 1;
  printf "[%@{[ $self->clad->host_length ]}s %-4s] ", $self->prefix, $code;
  print Term::ANSIColor::color('reset') if $self->is_color;
  print $line, "\n";
}

sub cv { shift->{cv} }

1;
