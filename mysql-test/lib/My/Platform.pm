# -*- cperl -*-
# Copyright (c) 2008 MySQL AB, 2008, 2009 Sun Microsystems, Inc.
# Use is subject to license terms.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1335  USA

package My::Platform;

use strict;
use File::Basename;
use File::Path;
use Carp;

use base qw(Exporter);
our @EXPORT= qw(IS_CYGWIN IS_MSYS IS_WINDOWS IS_WIN32PERL IS_AIX IS_MAC IS_FREEBSD
		native_path posix_path mixed_path
                check_socket_path_length process_alive open_for_append);

BEGIN {
  if ($^O eq "cygwin") {
    # Make sure cygpath works
    if ((system("cygpath > /dev/null 2>&1") >> 8) != 1){
      die "Could not execute 'cygpath': $!";
    }
    eval 'sub IS_CYGWIN { 1 }';
    eval 'sub IS_MSYS { 0 }';
  }
  elsif ($^O eq "msys") {
    eval 'sub IS_CYGWIN { 1 }';
    eval 'sub IS_MSYS { 1 }';
  }
  else {
    eval 'sub IS_CYGWIN { 0 }';
    eval 'sub IS_MSYS { 0 }';
  }
  if ($^O eq "MSWin32") {
    eval 'sub IS_WIN32PERL { 1 }';
  }
  else {
    eval 'sub IS_WIN32PERL { 0 }';
  }
}

BEGIN {
  if (IS_CYGWIN or IS_WIN32PERL) {
    eval 'sub IS_WINDOWS { 1 }';
  }
  else {
    eval 'sub IS_WINDOWS { 0 }';
  }
}

BEGIN {
  if ($^O eq "aix") {
    eval 'sub IS_AIX { 1 }';
  }
  else {
    eval 'sub IS_AIX { 0 }';
  }
}

BEGIN {
  if ($^O eq "darwin") {
    eval 'sub IS_MAC { 1 }';
  }
  else {
    eval 'sub IS_MAC { 0 }';
  }
}

BEGIN {
  if ($^O eq "freebsd") {
    eval 'sub IS_FREEBSD { 1 }';
  }
  else {
    eval 'sub IS_FREEBSD { 0 }';
  }
}

#
# native_path
# Convert from path format used by perl to the underlying
# operating systems format
#
# NOTE
#  Used when running windows binaries (that expect windows paths)
#  in cygwin perl (that uses unix paths)
#

use Memoize;
if (!IS_WIN32PERL){
  memoize('mixed_path');
  memoize('native_path');
  memoize('posix_path');
}

sub mixed_path {
  my ($path)= @_;
  if (IS_CYGWIN){
    return unless defined $path;
    my $cmd= "cygpath -m $path";
    $path= `$cmd` or
      print "Failed to run: '$cmd', $!\n";
    chomp $path;
  }
  return $path;
}

sub native_path {
  my ($path)= @_;
  if (IS_CYGWIN) {
    # \\\\ protects against 2 expansions (just for the case)
    $path=~ s/\/+|\\+/\\\\\\\\/g;
  }
  elsif (IS_WINDOWS) {
    $path=~ s/\/+/\\/g;
  }
  return $path;
}

sub posix_path {
  my ($path)= @_;
  if (IS_CYGWIN){
    return unless defined $path;
    $path= `cygpath $path`;
    chomp $path;
  }
  return $path;
}

use File::Temp qw /tempdir/;

sub check_socket_path_length {
  my ($path)= @_;

  return 0 if IS_WINDOWS;
  # This may not be true, but we can't test for it on AIX due to Perl bug
  # See Bug #45771
  return 0 if ($^O eq 'aix');
  # See Debian bug #670722 - failing on kFreeBSD even after setting short path
  return 0 if $^O eq 'gnukfreebsd' and length $path < 40;
  # GNU/Hurd doesn't have hostpath(), but no limitation either
  return 0 if $^O eq 'gnu';

  require IO::Socket::UNIX;

  my $truncated= undef;

  # Create a tempfile name with same length as "path"
  my $tmpdir = tempdir( CLEANUP => 0);
  my $len = length($path) - length($tmpdir) - 1;
  my $testfile = $tmpdir . "/" . "x" x ($len  > 0 ? $len : 1);
  my $sock;
  eval {
    $sock= new IO::Socket::UNIX
      (
       Local => $testfile,
       Listen => 1,
      );
    $truncated= 1; # Be negative

    die "Could not create UNIX domain socket: $!"
      unless defined $sock;

    die "UNIX domain socket path was truncated"
      unless ($testfile eq $sock->hostpath());

    $truncated= 0; # Yes, it worked!

  };

  die "Unexpected failure when checking socket path length: $@"
    if $@ and not defined $truncated;

  $sock= undef;  # Close socket
  rmtree($tmpdir); # Remove the tempdir and any socket file created
  return $truncated;
}


sub process_alive {
  my ($pid)= @_;
  die "usage: process_alive(pid)" unless $pid;

  return kill(0, $pid) unless IS_WINDOWS;

  my @list= split(/,/, `tasklist /FI "PID eq $pid" /NH /FO CSV`);
  my $ret_pid= eval($list[1]);
  return ($ret_pid == $pid);
}



use Symbol qw( gensym );

use if $^O eq 'MSWin32', 'Win32API::File', qw( CloseHandle CreateFile GetOsFHandle OsFHandleOpen  OPEN_ALWAYS FILE_APPEND_DATA 
  FILE_SHARE_READ FILE_SHARE_WRITE FILE_SHARE_DELETE );
use if $^O eq 'MSWin32', 'Win32::API';

use constant WIN32API_FILE_NULL => [];

# Open a file for append
# On Windows we use CreateFile with FILE_APPEND_DATA
# to insure that writes are atomic, not interleaved
# with writes by another processes. 
sub open_for_append
{
  my ($file) = @_;
  my $fh = gensym();

  if (IS_WIN32PERL)
  {
    my $handle;
    if (!($handle = CreateFile(
        $file,
        FILE_APPEND_DATA(),
        FILE_SHARE_READ()|FILE_SHARE_WRITE()|FILE_SHARE_DELETE(),
        WIN32API_FILE_NULL,
        OPEN_ALWAYS(),# Create if doesn't exist.
        0,
        WIN32API_FILE_NULL,
      )))
    {
      return undef;
    }

    if (!OsFHandleOpen($fh, $handle, 'wat'))
    {
      CloseHandle($handle);
      return undef;
    }
    return $fh;
  }
  
  open($fh,">>",$file) or return undef;
  return $fh;
}


sub check_cygwin_subshell
{
  # Only pipe (or sh-expansion) is fed to /bin/sh
  my $out= `echo %comspec%|cat`;
  return ($out =~ /\bcmd.exe\b/) ? 0 : 1;
}

sub install_shell_wrapper()
{
  system("rm -f /bin/sh.exe") and die $!;
  my $wrapper= <<'EOF';
#!/bin/bash
if [[ -n "$MTR_PERL" && "$1" = "-c" ]]; then
 shift
 exec $(cygpath -m "$COMSPEC") /C "$@"
fi
exec /bin/bash "$@"
EOF
  open(OUT, '>', "/bin/sh") or die "/bin/sh: $!\n";
  print OUT $wrapper;
  close(OUT);
  system("chmod +x /bin/sh") and die $!;
  print "Cygwin subshell wrapper /bin/sh was installed, please restart MTR!\n";
  exit(0);
}

sub uninstall_shell_wrapper()
{
  system("rm -f /bin/sh") and die $!;
  system("cp /bin/bash.exe /bin/sh.exe") and die $!;
}

sub cygwin_subshell_fix
{
  my ($opt_name, $opt_value)= @_;
  if ($opt_name ne "cygwin-subshell-fix") {
    confess "Wrong option name: ${opt_name}";
  }
  if ($opt_value eq "do") {
    if (check_cygwin_subshell()) {
      install_shell_wrapper();
    } else {
      print "Cygwin subshell fix was already installed, skipping...\n";
    }
  } elsif ($opt_value eq "remove") {
    if (check_cygwin_subshell()) {
      print "Cygwin subshell fix was already uninstalled, skipping...\n";
    } else {
      uninstall_shell_wrapper();
    }
  } else {
    die "Wrong --cygwin-subshell-fix value: ${opt_value} (expected do/remove)";
  }
}

sub options
{
  if (IS_CYGWIN) {
    return ('cygwin-subshell-fix=s'         => \&cygwin_subshell_fix);
  } else {
    return ();
  }
}


1;
