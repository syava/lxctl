package Lxctl::create;

use strict;
use warnings;
use autodie qw(:all);

use Getopt::Long qw(GetOptionsFromArray);

use Lxc::object;

use Lxctl::set;
use LxctlHelpers::config;
use LxctlHelpers::helper;
use Data::UUID;
use File::Path;

my $config = new LxctlHelpers::config;
my $helper = new LxctlHelpers::helper;

my %options = ();

my $lxc;
my $yaml_conf_dir;
my $lxc_conf_dir;
my $root_mount_path;
my $templates_path;
my $vg;

my @args;

sub check_existance
{
	my $self = shift;

	die "Container lxc conf directory $lxc_conf_dir/$options{'contname'} already exists!\n\n" 
		if -e "$lxc_conf_dir/$options{'contname'}";
	die "Container root directory $root_mount_path/$options{'contname'} already exists!\n\n"
		if -e "$root_mount_path/$options{'contname'}";
	die "Container root logical volume /dev/$vg/$options{'contname'} already exists!\n\n"
		if -e "/dev/$vg/$options{'contname'}";

	if ($options{'empty'} == 0) {
		if (! -e "$templates_path/$options{'ostemplate'}.tar.gz") {
			die "There is no such template: $templates_path/$options{'ostemplate'}.tar.gz\n\n";
		}
	}

	if ($options{'roottype'} eq 'raw') {
		die "Specify raw device using '--device' option!\n" unless $options{'device'};
		my $device = $options{'device'};
		if (! -e $device ) {
			die "No such device: $device\n";
		} else {
			open(my $mounts, "<", "/proc/mounts");
			while(<$mounts>) {
				die "$device is already mounted, please double check your options!\n" if /$device/;
			}
			close($mounts);
		}
	}

	return;
}

sub create_root
{
	my $self = shift;

	if ($options{'rootsz'} ne 'share') {
		if (lc($options{'roottype'}) eq 'lvm') {
			$helper->lvcreate($options{'contname'}, $vg, $options{'rootsz'});

			$helper->mkfs($options{'fs'}, "/dev/$vg/$options{'contname'}",   $options{'mkfsopts'});
		} elsif (lc($options{'roottype'}) eq 'raw') {
			$helper->mkfs($options{'fs'}, $options{'device'}, $options{'mkfsopts'});
		} elsif (lc($options{'roottype'}) eq 'file') {
			print "Creating root in file: $root_mount_path/$options{'contname'}.raw\n";

			my $bs = 4096;
			my $count = $lxc->convert_size($options{'rootsz'}, 'b')/$bs;

			# Creating empty file of desired size. It's a bit slower than system dd, but still rather fast (around 10% slower than dd)
			system("dd if=/dev/zero of=$root_mount_path/$options{'contname'}.raw bs=$bs count=$count");
#			open my $raw_file, '>' , "$root_mount_path/$options{'contname'}.raw";
#			print $raw_file "\0" x($count*$bs);
#			close ($raw_file);

			$helper->mkfs($options{'fs'}, "$root_mount_path/$options{'contname'}.raw", $options{'mkfsopts'});
		}
	}

	print "Creating directory: $root_mount_path/$options{'contname'}\n";

	mkpath("$root_mount_path/$options{'contname'}/rootfs");

	if ($options{'rootsz'} ne 'share') {
		print "Fixing fstab...\n";

		my $what_to_mount = "";
		my $additional_opts = "";
		if (lc($options{'roottype'}) eq 'lvm') {
			$what_to_mount = "/dev/$vg/$options{'contname'}";
		} elsif (lc($options{'roottype'}) eq 'raw') {
			$what_to_mount = $options{'device'};
		} elsif (lc($options{'roottype'}) eq 'file') {
			$what_to_mount = "$root_mount_path/$options{'contname'}.raw";
			$additional_opts=",loop";
		}
		# TODO: We discussed and decided to keep all mounts in array of hashes in yaml file and apply on start.
		my %root_mp = (
			'from' => "$what_to_mount",
			'to' => "$root_mount_path/$options{'contname'}",
			'fs' => "$options{'fs'}",
			'opts' => "$options{'mountoptions'}$additional_opts",
			);

		$options{'rootfs_mp'} = \%root_mp;
		print "Mounting FS...\n";

		system("mount -t $root_mp{'fs'} -o $root_mp{'opts'} $root_mp{'from'} $root_mp{'to'} 1>/dev/null");
	}

	return;
}

sub check_create_options
{
	my $self = shift;
	$Getopt::Long::passthrough = 1;

	GetOptions(\%options, 'ipaddr=s', 'hostname=s', 'ostemplate=s', 
		'config=s', 'roottype=s', 'device=s', 'root=s', 'rootsz=s', 'netmask|mask=s',
		'defgw|gw=s', 'dns=s', 'macaddr=s', 'autostart=s', 'empty!',
		'save!', 'load=s', 'debug', 'searchdomain=s', 'tz=s',
		'fs=s', 'mkfsopts=s', 'mountoptions=s', 'mtu=i', 'userpasswd=s',
		'pkgopt=s', 'addpkg=s', 'ifname=s');

	if (defined($options{'load'})) {
		if ( ! -f $options{'load'}) {
			print "Cannot find config-file $options{'load'}, ignoring...\n";
			last;
		};

		my $result = $config->load_file($options{'load'});
		my %opts_new = %$result;

		foreach my $key (sort keys %options) {
			$opts_new{$key} = $options{$key};
		};

		%options = %opts_new;
	}

	if (!defined($options{'contname'})) {
		die "No container name specified\n\n";
	}

	my $ug = new Data::UUID;
	$options{'uuid'} = $ug->create_str();

	$options{'ostemplate'} ||= $config->get_option_from_main('os', 'OS_TEMPLATE');
	$options{'config'} ||= "$lxc_conf_dir/$options{'contname'}";
	$options{'root'} ||= "$root_mount_path/$options{'contname'}";
	$options{'rootsz'} ||= $config->get_option_from_main('root', 'ROOT_SIZE');
	$options{'autostart'} ||= "1";
	$options{'roottype'} ||= $config->get_option_from_main('root', 'ROOT_TYPE');

	if (!defined($options{'empty'})) {
		$options{'empty'} = 0;
	}

	$options{'debug'} ||= 0;

	if (!defined($options{'save'})) {
		$options{'save'} = 1;
	}

	if ($options{'empty'} == 0) {
		$options{'ipaddr'} || print "You did not specify IP address! Using default.\n";
		if (! $options{'ipaddr'} =~ m/\d+\.\d+\.\d+\.\d+\/\d+/ ) {
			$options{'netmask'} || print "You did not specify network mask! Using default.\n";
		}
		$options{'defgw'} || print "You did not specify default gateway! Using default.\n";
		$options{'dns'} || print "You did not specify DNS! Using default.\n";
	}

	my @domain_tokens = split(/\./, $options{'contname'});
	my $tmp_hostname = shift @domain_tokens;
	$options{'hostname'} ||= $tmp_hostname;
	$options{'searchdomain'} ||= join '.', @domain_tokens;
	if ($options{'searchdomain'} eq "") {
		$options{'searchdomain'} = $config->get_option_from_main('set', 'SEARCHDOMAIN');
	}

	if ($options{'debug'}) {
		foreach my $key (sort keys %options) {
			print "options{$key} = $options{$key} \n";
		};
	}
	$options{'fs'} ||= $config->get_option_from_main('fs', 'FS');
	$options{'mkfsopts'} ||= $config->get_option_from_main('fs', 'FS_OPTS');
	$options{'mountoptions'} ||= $config->get_option_from_main('fs', 'FS_MOUNT_OPTS');

	return $options{'uuid'};
}

sub deploy_template
{
	my $self = shift;

	my $template = "$templates_path/$options{'ostemplate'}.tar.gz";
	print "Deploying template: $template\n";

	system("tar xf $template -C $root_mount_path/$options{'contname'} 1>/dev/null");

	return;
}

sub create_lxc_conf
{
	my $self = shift;

	print "Creating lxc configuration file: $lxc_conf_dir/$options{'contname'}/config\n";	

	mkpath("$lxc_conf_dir/$options{'contname'}");

        my $confdir = '/etc/lxctl/conf.d/';
        opendir(my $dh, $confdir) || die "Can't open directory $confdir: $!\n";
        my @configs = grep { /\.conf$/ && -f "$confdir/$_" } readdir($dh);
        my $conftmpl = "$lxc_conf_dir/$options{'contname'}/config.tmpl";
        my $confmain = "$lxc_conf_dir/$options{'contname'}/config";
        if (-f $confmain) {
            unlink $confmain
        }

        open(MAINCONF, '>>', $confmain) || die "Can't open file $confmain for write: $!\n";
        foreach my $conf (@configs) {
            open (FH, '<', "/etc/lxctl/conf.d/$conf") or die "Can't read file $conf: $!\n";
            while (my $line = <FH>) {
                $line =~ s/_CT_NAME_/$options{'contname'}/g;
                $line =~ s/_ROOTFS_PATH_/$root_mount_path\/$options{'contname'}\/rootfs/g;
                $line =~ s/_MOUNT_FSTAB_/$lxc_conf_dir\/$options{'contname'}\/fstab/g;
                print MAINCONF $line;
            }
            close(FH);
        }
        close(MAINCONF);

	my $fstab = "\
proc			$root_mount_path/$options{'contname'}/rootfs/proc		 proc	nodev,noexec,nosuid 0 0
sysfs		   $root_mount_path/$options{'contname'}/rootfs/sys		  sysfs defaults  0 0
";

	open my $fstab_file, '>', "$lxc_conf_dir/$options{'contname'}/fstab";
	print $fstab_file $fstab;
	close($fstab_file);

	return;
}

sub create_ssh_keys
{
	my $self = shift;

	print "Regenerating SSH keys...\n";

	eval {
		system("rm $root_mount_path/$options{'contname'}/rootfs/etc/ssh/ssh_host_*");
		1;
	} or do {
		print "Failed to delete old ssh keys!\n\n";
	};

	system("ssh-keygen -q -t rsa -f $root_mount_path/$options{'contname'}/rootfs/etc/ssh/ssh_host_rsa_key -N ''");
	system("ssh-keygen -q -t dsa -f $root_mount_path/$options{'contname'}/rootfs/etc/ssh/ssh_host_dsa_key -N ''");
}

sub deploy_packets
{
	my $self = shift;

	defined($options{'addpkg'}) or return;
	$options{'pkgopt'} ||= "";

	$options{'addpkg'} =~ s/,/ /g;

	print "Adding packages: $options{'addpkg'}\n";

	## Deb only
	system("chroot $root_mount_path/$options{'contname'}/rootfs/ apt-get $options{'pkgopt'} install $options{'addpkg'}");

	return;
}


sub do
{
	my ($self) = shift;

	$options{'contname'} = $_[0]
		or die "Name the container please!\n\n";

	if ( $options{'contname'} =~ m/^-/ ) {
		print "Command specified instead of container name, trying to parse...\n";
		undef($options{'contname'});
	} else {
		shift;
	}

	$self->check_create_options();
	$self->check_existance();
	print "Creating container $options{'contname'}...\n";
	$self->create_root();
	$self->create_lxc_conf();

	if (!defined($options{'ifname'})) {
		eval {
			$options{'ifname'} = $config->get_option_from_main('set', "IFNAME");
			1;
		} or do {
			$options{'ifname'} = "mac";
		};
	}

	my $setter = Lxctl::set->new(%options);
	$setter->set_macaddr();

	if ($options{'empty'} == 0) {
		$self->deploy_template();
		$self->create_ssh_keys();

		$setter->set_ipaddr();
		$setter->set_netmask();
		$setter->set_defgw();
		$setter->set_dns();
		$setter->set_hostname();
		$setter->set_searchdomain();
		$setter->set_tz();
		$setter->set_mtu();
		$setter->set_userpasswd();
		$setter->set_ifname();

		$self->deploy_packets();
	}

	$setter->set_autostart();

	$options{'api_ver'} = $config->get_api_ver();

	$options{'save'} && $config->save_hash(\%options, "$yaml_conf_dir/$options{'contname'}.yaml");

	print "Container $options{'contname'}' created.\n";

	return;
}

sub new
{
	my $class = shift;
	my $self = {};
	bless $self, $class;

	$lxc = new Lxc::object;

	$root_mount_path = $lxc->get_roots_path();
	$templates_path = $lxc->get_template_path();
	$yaml_conf_dir = $lxc->get_config_path();
	$lxc_conf_dir = $lxc->get_lxc_conf_dir();
	$vg = $lxc->get_vg();

	return $self;
}

1;
__END__

=head1 AUTHOR

Anatoly Burtsev, E<lt>anatolyburtsev@yandex.ruE<gt>
Pavel Potapenkov, E<lt>ppotapenkov@gmail.comE<gt>
Vladimir Smirnov, E<lt>civil.over@gmail.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2011 by Anatoly Burtsev, Pavel Potapenkov, Vladimir Smirnov

This library is free software; you can redistribute it and/or modify
it under the same terms of GPL v2 or later, or, at your opinion
under terms of artistic license.

=cut
