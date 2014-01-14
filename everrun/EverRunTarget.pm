# Sys::VirtConvert::Connection::EverRunTarget
# Copyright (C) 2013 Stratus Technologies Inc.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA

use strict;
use warnings;

package everrun_util;
use Sys::VirtConvert::Util qw(:DEFAULT rhev_helper);
sub get_uuid
{
    logmsg NOTICE, "EverRunTarget:get_uuid";
    my $uuidgen;
    open($uuidgen, '-|', 'uuidgen') or die("Unable to execute uuidgen: $!");

    my $uuid;
    while(<$uuidgen>) {
        chomp;
        $uuid = $_;
    }
    close($uuidgen) or die("uuidgen returned an error");

    return $uuid;
}

sub get_doh_session
{
    logmsg NOTICE, "EverRunTarget:get_doh_session";
    my $doh_cred_file = "/root/creds";
    unless (-e $doh_cred_file) {
	v2vdie __('Failed: Everrun Doh credentials file does not exist');
    }
    open my $file, '<', $doh_cred_file; 
    my $pw = <$file>;
    close $file;
    my $cmd_curl_login = "curl  -b cookie_file -c cookie_file -H \"Content-type: text/xml\" -d \"<requests output='XML'><request id='1' target='session'><login><username>root</username><password>$pw</password></login></request></requests>\" http://localhost/doh/";
    my $eh = Sys::VirtConvert::ExecHelper->run($cmd_curl_login);    
    v2vdie __x('Failed get cookie file for Everrun doh login '.
	       'Error was: {error}',
	       error => $eh->output()) if $eh->status() != 0;
    return;
}

package Sys::VirtConvert::Connection::EverRunTarget::WriteStream;

use File::Spec::Functions qw(splitpath);
use POSIX;

use Sys::VirtConvert::ExecHelper;
use Sys::VirtConvert::Util qw(:DEFAULT rhev_helper);

use Locale::TextDomain 'virt-v2v';

our @streams;

sub new
{
    logmsg NOTICE, "EverRunTarget::WriteStream:new";
    my $class = shift;
    my ($volume, $convert) = @_;

    my $self = {};
    bless($self, $class);

    # Store a reference to ourself
    push(@streams, $self);

    $self->{written} = 0;
    $self->{volume} = $volume;
    my $path = $volume->get_path();
    my $format = $volume->get_format();
    
    my $transfer = new Sys::VirtConvert::Transfer::Local
	($path, 0, $format, $volume->is_sparse());
    $self->{writer} = $transfer->get_write_stream($convert);
    
    return $self;
}

sub _write_metadata
{
    logmsg NOTICE, "EverRunTarget::WriteStream:_write_metadata";
    return;
}

sub write
{
    logmsg NOTICE, "EverRunTarget::WriteStream:write";
    my $self = shift;
    my ($buf) = @_;

    $self->{writer}->write($buf);
    $self->{written} += length($buf);
}

sub close
{
    logmsg NOTICE, "EverRunTarget::WriteStream:close";
    my $self = shift;

    # Nothing to do if we've already closed the writer
    my $writer = $self->{writer};
    return unless (defined($writer));
    delete($self->{writer});

    # Pad the file up to a 512 byte boundary
    my $pad = (512 - ($self->{written} % 512)) % 512;
    $writer->write("\0" x $pad) if ($pad);

    $writer->close();

    # Update the volume's disk usage
    my $volume = $self->{volume};
    $volume->{usage} = $writer->get_usage();

    $self->_write_metadata();
}

# Immediately close all open WriteStreams
sub _cleanup
{
    logmsg NOTICE, "EverRunTarget::WriteStream:_cleanup";
    my $stream;
    while ($stream = shift(@streams)) {
        eval {
            delete($stream->{writer});
        };
        warn($@) if ($@);
    }
}

sub DESTROY
{
    exit(0);
    logmsg NOTICE, "EverRunTarget::WriteStream:DESTROY";
    my $self = shift;

    my $err = $?;

    $self->close();

    $? |= $err;

    # Remove the global reference
    @streams = grep { defined($_) && $_ != $self } @streams;
}


package Sys::VirtConvert::Connection::EverRunTarget::Transfer;

use Sys::VirtConvert::Util;

use Carp;
use Locale::TextDomain 'virt-v2v';

sub new
{
    logmsg NOTICE, "EverRunTarget::Transfer:new";
    my $class = shift;
    my ($volume) = @_;

    my $self = {};
    bless($self, $class);

    $self->{volume} = $volume;

    return $self;
}

sub local_path
{
    logmsg NOTICE, "EverRunTarget::Transfer:local_path";
    return shift->{volume}->get_path();
}

sub get_read_stream
{
    logmsg NOTICE, "EverRunTarget::Transfer:get_read_stream";
    v2vdie __('Unable to read data from EVERRUN.');
}

sub get_write_stream
{
    logmsg NOTICE, "EverRunTarget::Transfer:get_write_stream";
    my $self = shift;
    my ($convert) = @_;

    my $volume = $self->{volume};
    return new Sys::VirtConvert::Connection::EverRunTarget::WriteStream($volume,
                                                                     $convert);
}

sub DESTROY
{
    exit(0);
    logmsg NOTICE, "EverRunTarget::Transfer:DESTROY";
    # Remove circular reference
    delete(shift->{volume});
}


package Sys::VirtConvert::Connection::EverRunTarget::Vol;

use File::Spec::Functions;
use File::Temp qw(tempdir);
use POSIX;

use Sys::VirtConvert::Util qw(:DEFAULT rhev_helper);
use Locale::TextDomain 'virt-v2v';

our %vols_by_path;
our @vols;
our $tmpdir;

@Sys::VirtConvert::Connection::EverRunTarget::Vol::ISA =
    qw(Sys::VirtConvert::Connection::Volume);

sub new
{
    logmsg NOTICE, "EverRunTarget::Vol:new";
    my $class = shift;
    my ($mountdir, $volname, $format, $insize, $sparse) = @_;

    my $imageuuid = everrun_util::get_uuid();

    logmsg NOTICE, "EverRunTarget::Vol:new name=$volname mountdir=$mountdir, format=$format, insize=$insize, sparse=$sparse";

    #Fix size for Everrun
    my $newsize = ceil($insize/(1024*1024))+1024;
    everrun_util::get_doh_session();
    my $cmd_curl_create_vol = "curl  -s -b cookie_file -c cookie_file -H \"Content-type: text/xml\" -d \"<requests output='XML'><request id='1' target='volume'><create><volume from='storagegroup:o21'><size>$newsize</size><hard>true</hard><name>$volname</name><description>p2v created disk</description></volume></create></request></requests>\" http://localhost/doh/";
    logmsg NOTICE, "EverRunTarget::Vol:new cmd_curl_create_vol = $cmd_curl_create_vol";
    my $eh = Sys::VirtConvert::ExecHelper->run($cmd_curl_create_vol);
    v2vdie __x('Failed to create new Everrun volume '.
	       'Error was: {error}',
	       error => $eh->output()) if $eh->status() != 0;
    my $volpath ="";
    my $ret = $eh->output();
    $ret =~ m/path=\"(.*)\"/;
    $volpath = $1;
    logmsg NOTICE, "EverRunTarget::Vol:new volpath = $volpath";
    $ret =~ m/id=\"(volume:o\d+)\"/;
    my $voluuid = $1;
    logmsg NOTICE, "EverRunTarget::Vol:new voluuid = $voluuid";    

    my $cmd_qemu_img = "qemu-img info $volpath";
    $eh = Sys::VirtConvert::ExecHelper->run($cmd_qemu_img);
    v2vdie __x('Failed to create new Everrun volume '.
	       'Error was: {error}',
	       error => $eh->output()) if $eh->status() != 0;

    $eh->output() =~ m/virtual\s+size:\s+\S+G\s+\((\d+)\s+bytes\)/;
    my $imagesize = $1;

    # EVERRUN needs disks to be a multiple of 512 in size. We'll pad up to this
    # size if necessary.
    my $outsize = $insize;

    my $creation = time();

    my $self = $class->SUPER::new($imageuuid, $format, $volpath, $outsize,
                                  undef, $sparse, 0);
    $self->{transfer} =
        new Sys::VirtConvert::Connection::EverRunTarget::Transfer($self);

    $self->{imageuuid}  = $imageuuid;
    $self->{imagesize}  = $imagesize;
    $self->{voluuid}    = $voluuid;
    $self->{volname} = $volname;
    $self->{volpath} = $volpath;
    $self->{creation} = $creation;

    # Convert format into something EVERRUN understands
    my $everrun_format;
    if ($format eq 'raw') {
        $self->{everrun_format} = 'RAW';
    } elsif ($format eq 'qcow2') {
        $self->{everrun_format} = 'COW';
    } else {
        v2vdie __x('EVERRUN cannot handle volumes of format {format}',
                   format => $format);
    }

    # Generate the EVERRUN type
    # N.B. This must be in mixed case in the OVF, but in upper case in the .meta
    # file. We store it in mixed case and convert to upper when required.
    $self->{everrun_type} = $sparse ? 'Sparse' : 'Preallocated';

    $vols_by_path{$volpath} = $self;
    push(@vols, $self);

    return $self;
}

sub _get_by_path
{
    logmsg NOTICE, "EverRunTarget::Vol:_get_by_path";
    my $class = shift;
    my ($path) = @_;

    return $vols_by_path{$path};
}

sub _get_domainuuid
{
    logmsg NOTICE, "EverRunTarget::Vol:_get_domain_uuid";
    return shift->{domainuuid};
}

sub _get_imageuuid
{
    logmsg NOTICE, "EverRunTarget::Vol:_get_imageuuid";
    return shift->{imageuuid};
}

sub _get_imagesize
{
    logmsg NOTICE, "EverRunTarget::Vol:_get_imagesize";
    return shift->{imagesize};
}

sub _get_voluuid
{
    logmsg NOTICE, "EverRunTarget::Vol:_get_voluuid";
    return shift->{voluuid};
}

sub _get_volpath
{
    logmsg NOTICE, "EverRunTarget::Vol:_get_volpath";
    return shift->{volpath};
}

sub _get_creation
{
    logmsg NOTICE, "EverRunTarget::Vol:_get_creation";
    return shift->{creation};
}

sub _get_everrun_format
{
    logmsg NOTICE, "EverRunTarget::Vol:_get_everrun_format";
    return shift->{everrun_format};
}

sub _get_everrun_type
{
    logmsg NOTICE, "EverRunTarget::Vol:_get_everrun_type";
    return shift->{everrun_type};
}

sub _cleanup
{
    logmsg NOTICE, "EverRunTarget::Vol:_cleanup";
    my $class = shift;

    return unless (defined($tmpdir));

    my $ret = system('rm', '-rf', $tmpdir);
    if (WEXITSTATUS($ret) != 0) {
        logmsg WARN, __x('Error whilst attempting to remove temporary '.
                         'directory {dir}', dir => $tmpdir);
    }
    $tmpdir = undef;
}

package Sys::VirtConvert::Connection::EverRunTarget;

use File::Temp qw(tempdir);
use File::Spec::Functions;
use POSIX;
use Time::gmtime;

use Sys::VirtConvert::ExecHelper;
use Sys::VirtConvert::Util qw(:DEFAULT rhev_helper rhev_ids);
use XML::Simple;
use Locale::TextDomain 'virt-v2v';

=head1 NAME

Sys::VirtConvert::Connection::EverRunTarget - Output to a EVERRUN Export storage
domain

=head1 METHODS

=over

=item Sys::VirtConvert::Connection::EverRunTarget->new(domain_path)

Create a new Sys::VirtConvert::Connection::EverRunTarget object.

=over

=item domain_path

The NFS path to an initialised EVERRUN Export storage domain.

=back

=cut

sub new
{
    logmsg NOTICE, "EverRunTarget:new";
    my $class = shift;
    my ($domain_path) = @_;

    # Must do this before bless, or DESTROY will be called
    v2vdie __('You must be root to output to EVERRUN') unless $> == 0;

    my $self = {};
    bless($self, $class);
    $self->{domain_path} = $domain_path;

    return $self;
}

sub DESTROY
{
    exit(0);
    logmsg NOTICE, "EverRunTarget:destroy";
    my $self = shift;

    # The ExecHelper we use to unmount the export directory will overwrite $?
    # when the helper process exits. We need to preserve it for our own exit
    # status.
    my $retval = $?;

    eval {
        # Ensure there are no remaining writer processes
        Sys::VirtConvert::Connection::EverRunTarget::WriteStream->_cleanup();

	# Cleanup the volume temporary directory
	Sys::VirtConvert::Connection::EverRunTarget::Vol->_cleanup();
    };
    if ($@) {
        warn($@);
        $retval |= 1;
    }

    my $eh = Sys::VirtConvert::ExecHelper->run('umount', $self->{mountdir});
    if ($eh->status() != 0) {
        logmsg WARN, __x('Failed to unmount {path}. Command exited with '.
                         'status {status}. Output was: {output}',
                         path => $self->{domain_path},
                         status => $eh->status(),
                         output => $eh->output());
        # Exit with an error if the child failed.
        $retval |= $eh->status();
    }

    unless (rmdir($self->{mountdir})) {
        logmsg WARN, __x('Failed to remove mount directory {dir}: {error}',
                         dir => $self->{mountdir}, error => $!);
        $retval |= 1;
    }

    $? |= $retval;
}

=item create_volume(name, format, size, is_sparse)

Create a new volume in the export storage domain

=over

=item name

The name of the volume which is being created.

=item format

The file format of the target volume, as returned by qemu.

=item size

The size of the volume which is being created in bytes.

=item is_sparse

1 if the target volume is sparse, 0 otherwise.

=back

create_volume() returns a Sys::VirtConvert::Connection::EverRunTarget::Vol object.

=cut

sub create_volume
{
    logmsg NOTICE, "EverRunTarget:create_volume";
    my $self = shift;
    my ($name, $format, $size, $is_sparse) = @_;

    return Sys::VirtConvert::Connection::EverRunTarget::Vol->new
        ($self->{mountdir}, $name, $format, $size, $is_sparse);
}

=item volume_exists(name)

Check if volume I<name> exists in the target storage domain.

Always returns 0, as EVERRUN storage domains don't have names

=cut

sub volume_exists
{
    logmsg NOTICE, "EverRunTarget:volume_exists";
    return 0;
}

=item get_volume(name)

Not defined for EVERRUN output

=cut

sub get_volume
{
    logmsg NOTICE, "EverRunTarget:get_volume";
    my $self = shift;
    my ($name) = @_;

    die("Cannot retrieve an existing EVERRUN storage volume by name");
}

=item guest_exists(name)

This always returns 0 for a EVERRUN target.

=cut

sub guest_exists
{
    logmsg NOTICE, "EverRunTarget:guest_exists";
    return 0;
}

=item create_guest(g, root, meta, config, guestcaps, output_name)

Create the guest in the target

=cut

sub create_guest
{
    logmsg NOTICE, "EverRunTarget:create_guest";
    my $self = shift;
    my ($g, $root, $meta, $config, $guestcaps, $output_name) = @_;

    # Get the number of virtual cpus
    my $ncpus = $meta->{cpus};

    # Get the amount of memory in MB
    my $memsize = ceil($meta->{memory}/1024/1024);

    # Generate a creation date
    my $vmcreation = _format_time(gmtime());

    my $vmuuid = everrun_util::get_uuid();

    my $ostype = _get_os_type($g, $root);
    my $vmtype = _get_vm_type($g, $root, $meta);

    everrun_util::get_doh_session();    
    my $cmd_curl_create_guest =  "curl  -b cookie_file -c cookie_file -H \"Content-type: text/xml\" -d \"<requests output='XML'><request id='1' target='vm'><create-dynamic><name>$output_name</name><description></description><virtual-cpus>$ncpus</virtual-cpus><memory>$memsize</memory><availability-level>FT</availability-level><virtualization>hvm</virtualization><autostart>false</autostart>";

    my $disk_xml = $self->_disks($meta, $guestcaps);
    my $network_xml = $self->_networks($meta, $config, $guestcaps);
    
    $cmd_curl_create_guest .= $disk_xml.$network_xml."</create-dynamic></request></requests>\" http://localhost/doh/";
    logmsg NOTICE, "EverRunTarget:create_guest: cmd_curl_create_guest = $cmd_curl_create_guest";

    my $eh = Sys::VirtConvert::ExecHelper->run($cmd_curl_create_guest);
    v2vdie __x("Failed $cmd_curl_create_guest ".
	       "Error was: ".$eh->output()) if $eh->status() != 0;
}

# Work out how to describe the guest OS to EVERRUN. Possible values are:
#  Other
#   Not used
#
#  RHEL3
#  RHEL3x64
#   os = linux
#   distro = rhel
#   major_version = 3
#
#  RHEL4
#  RHEL4x64
#   os = linux
#   distro = rhel
#   major_version = 4
#
#  RHEL5
#  RHEL5x64
#   os = linux
#   distro = rhel
#   major_version = 5
#
#  OtherLinux
#   os = linux
#
#  WindowsXP
#   os = windows
#   major_version = 5
#   minor_version = 1
#
#  WindowsXP
#   os = windows
#   major_version = 5
#   minor_version = 2
#   product_name = 'Microsoft Windows XP'
#
#  Windows2003
#  Windows2003x64
#   os = windows
#   major_version = 5
#   minor_version = 2
#   N.B. This also matches Windows 2003 R2, which there's no option for
#
#  Windows2008
#  Windows2008x64
#   os = windows
#   major_version = 6
#   minor_version = 0
#   N.B. This also matches Vista, which there's no option for
#
#  Windows7
#  Windows7x64
#   os = windows
#   major_version = 6
#   minor_version = 1
#   product_variant = 'Client'
#
#  Windows2008R2x64
#   os = windows
#   major_version = 6
#   minor_version = 1
#   product_variant != 'Client'
#
#  Unassigned
#   None of the above
#
# N.B. We deliberately fall through to Unassigned rather than Other, because
# this represents a failure to match. We don't want to assert that the OS is not
# one of the above values in case we're wrong.
sub _get_os_type
{
    logmsg NOTICE, "EverRunTarget:_get_os_type";
    my ($g, $root) = @_;

    my $arch = $g->inspect_get_arch($root);

    my $arch_suffix = '';
    if ($arch eq 'x86_64') {
        $arch_suffix = 'x64';
    } elsif ($arch ne 'i386') {
        logmsg WARN, __x('Unsupported architecture: {arch}', arch => $arch);
        return undef;
    }

    my $type;

    $type = _get_os_type_linux($g, $root, $arch_suffix)
        if ($g->inspect_get_type($root) eq 'linux');
    $type = _get_os_type_windows($g, $root, $arch_suffix)
        if ($g->inspect_get_type($root) eq 'windows');

    return 'Unassigned' if (!defined($type));
    return $type;
}

sub _get_os_type_windows
{
    logmsg NOTICE, "EverRunTarget:_get_os_type_windows";
    my ($g, $root, $arch_suffix) = @_;

    my $major   = $g->inspect_get_major_version($root);
    my $minor   = $g->inspect_get_minor_version($root);
    my $product = $g->inspect_get_product_name($root);

    if ($major == 5) {
        if ($minor == 1 ||
            # Windows XP Pro x64 is identified as version 5.2
            ($minor == 2 && $product =~ /\bXP\b/))
        {
            # EVERRUN doesn't differentiate Windows XP by architecture
            return "WindowsXP";
        }

        if ($minor == 2) {
            return "Windows2003".$arch_suffix;
        }
    }

    if ($major == 6 && $minor == 0) {
        return "Windows2008".$arch_suffix;
    }

    if ($major == 6 && $minor == 1) {
        # The only 32 bit Windows 6.1 is Windows 7
        return "Windows7" if length($arch_suffix) == 0;

        # This API is new in libguestfs 1.10
        # If it's not present, we can't differentiate between Win7 and Win2k8r2
        # for amd64
        if (defined($g->can('inspect_get_product_variant')) &&
            $g->inspect_get_product_variant($root) eq 'Client')
        {
            return "Windows7".$arch_suffix;
        }

        return "Windows2008R2".$arch_suffix;
    }

    logmsg WARN, __x('Unknown Windows version: {major}.{minor}',
                     major => $major, minor => $minor);
    return undef;
}

sub _get_os_type_linux
{
    logmsg NOTICE, "EverRunTarget:_get_os_type_linux";
    my ($g, $root, $arch_suffix) = @_;

    my $distro  = $g->inspect_get_distro($root);
    my $major   = $g->inspect_get_major_version($root);

    # XXX: EVERRUN 2.2 doesn't support a RHEL 6 target, however EVERRUN 2.3+ will.
    # For the moment, we set RHEL 6 to be 'OtherLinux', however we will need to
    # distinguish in future between EVERRUN 2.2 target and EVERRUN 2.3 target to know
    # what is supported.
    if ($distro eq 'rhel' && $major < 6) {
        return "RHEL".$major.$arch_suffix;
    }

    # Unlike Windows, Linux has its own fall-through option
    return "OtherLinux";
}

use constant DESKTOP => 0;
use constant SERVER => 1;

sub _get_vm_type
{
    logmsg NOTICE, "EverRunTarget:_get_vm_type";
    my ($g, $root, $meta) = @_;

    # Return whatever we were explicitly passed on the command line
    my $vmtype = $meta->{vmtype};
    return $vmtype eq "desktop" ? DESKTOP : SERVER if (defined($vmtype));

    # Make an informed guess based on the OS type
    return _get_vm_type_linux($g, $root)
        if ($g->inspect_get_type($root) eq 'linux');

    return _get_vm_type_windows($g, $root)
        if ($g->inspect_get_type($root) eq 'windows');

    # Final fall-through is server
    return SERVER;
}

sub _get_vm_type_windows
{
    logmsg NOTICE, "EverRunTarget:_get_vm_type_windows";
    my ($g, $root) = @_;

    my $major   = $g->inspect_get_major_version($root);
    my $minor   = $g->inspect_get_minor_version($root);
    my $product = $g->inspect_get_product_name($root);

    if ($major == 5) {
        # Windows XP
        if ($minor == 1 ||
            # Windows XP Pro x64 is identified as version 5.2
            ($minor == 2 && $product =~ /\bXP\b/))
        {
            return DESKTOP;
        }

        # Windows 2003
        if ($minor == 2) {
            return SERVER;
        }
    }

    # Windows 2008 & Vista
    if ($major == 6 && $minor == 0) {
        return SERVER if $product =~ /\bServer\b/;
        return DESKTOP;
    }

    # Windows 2008r2 & 7
    if ($major == 6 && $minor == 1) {
        return SERVER if $product =~ /\bServer\b/;
        return DESKTOP;
    }

    return SERVER;
}

sub _get_vm_type_linux
{
    logmsg NOTICE, "EverRunTarget:_get_vm_type_linux";
    my ($g, $root) = @_;

    my $distro  = $g->inspect_get_distro($root);
    my $major   = $g->inspect_get_major_version($root);
    my $product = $g->inspect_get_product_name($root);

    if ($distro eq 'rhel') {
        if ($major >= 5) {
            # This is accurate for RHEL 5 and RHEL 6. We can only guess about
            # future versions of RHEL, but it's as good a guess as any. We
            # negate this test to ensure we default to SERVER if our guess is
            # wrong.
            return DESKTOP if $product !~ /\bServer\b/;
            return SERVER;
        }

        if ($major == 4 || $major == 3) {
            return SERVER if $product =~ /\b(ES|AS)\b/;
            return DESKTOP;
        }

        return SERVER if $major == 2;
    }

    elsif ($distro eq 'fedora') {
        return DESKTOP;
    }

    return SERVER;
}

sub _format_time
{
    logmsg NOTICE, "EverRunTarget:_format_time";
    my ($time) = @_;
    return sprintf("%04d/%02d/%02d %02d:%02d:%02d",
                   $time->year() + 1900, $time->mon() + 1, $time->mday(),
                   $time->hour(), $time->min(), $time->sec());
}

sub _disks
{
    logmsg NOTICE, "EverRunTarget:_disks";
    my $self = shift;
    my ($meta, $guestcaps) = @_;
    my $xml_vols = "<volumes>";
    my %vol_list = ();
    foreach my $disk (sort @{$meta->{disks}}) {
        my $path = $disk->{dst}->get_path();
        my $vol = Sys::VirtConvert::Connection::EverRunTarget::Vol->_get_by_path
            ($path);
        die('metadata contains path not written by virt-v2v: ', $path)
            unless defined($vol);
	my $voluuid = $vol->_get_voluuid();
	my $imagesize = $vol->_get_imagesize();
	my $volpath = $vol->_get_volpath;
	my $cmd_qemu_img_resize = "qemu-img resize $volpath $imagesize";
	logmsg NOTICE, "EverRunTarget:_disks:cmd_qemu_img_resize=$cmd_qemu_img_resize";
	logmsg NOTICE, "EverRunTarget:_disks:voluuid=$voluuid volpath=$volpath";
	my $eh = Sys::VirtConvert::ExecHelper->run($cmd_qemu_img_resize);
	v2vdie __x("Failed $cmd_qemu_img_resize ".
		   "Error was: ".$eh->output()) if $eh->status() != 0;
	$vol_list{$volpath} = $voluuid;
    }
    foreach my $sorted_path (sort keys %vol_list) {
	my $vol_id = $vol_list{$sorted_path};
	$xml_vols .= "<volume ref='$vol_id'/>";
    }
    $xml_vols .= "</volumes>";
    return $xml_vols;
}

sub _networks
{
    logmsg NOTICE, "EverRunTarget:_networks";
    my $self = shift;
    my ($meta, $config, $guestcaps) = @_;
    my $xml = new XML::Simple;

    everrun_util::get_doh_session();
    my $xml_data = `curl  -s -b cookie_file -c cookie_file -H \"Content-type: text/xml\" -d \"<requests output='XML'><request id='1' target='supernova'><watch /></request></requests>\" http://localhost/doh/`;    
    my $data = $xml->XMLin($xml_data,
			   KeyAttr => [],
			   ForceArray => ['disk', 'pdisk', 'alert', 'log', 'timestamp', 'host', 'vm', 'license', "local-network",
					  'q-link', 'quorum-server', 'sharedstorage', 'link', 'volume', 'volumeelement', 'user', 'lansegment',
					  'tz', 'buggrab', 'template', 'ntp-server', 'repository', 'vmsnapshotnetworkconfig',
					  'diskslot', 'vbd', 'sensor', 'vif', 'aggregration', 'supernova', 'vmsnapshotvolumeconfig',
					  'storage','card', 'cpu', 'networkport', 'storageport', 'localnetwork','vmsnapshot',
					  'storagepath', 'sharednetwork','supernovastats','vmstats', 'licensepanel','volumesnapshot',
					  'sharedstoragestats', 'sharednetworkstats','hoststats', 'kit', 'account', 'controller', 'enclosure',
					  'rollingrebootmonitor', 'storagegroup'],
	);
    foreach my $network (@{$data->{response}->{output}->{sharednetwork}}) {
	if ($network->{withPortal} eq "true") {
	    my $xml_network = "<networks><network ref=\'".$network->{id}."\'/></networks>";
	    return $xml_network;
	}
    }
    v2vdie __x("Failed to find an Everrun network device");
}

=back

=head1 COPYRIGHT

Copyright (C) 2013-2014 Stratus Technologies Inc.

=head1 LICENSE

Please see the file COPYING for the full license.

=cut

1;
