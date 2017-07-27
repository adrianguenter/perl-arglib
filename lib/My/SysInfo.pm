package My::SysInfo;

use 5.018;
use utf8;
use warnings;

use Cwd             qw(abs_path);
use Data::Dumper    qw(Dumper);
use File::Basename;
use File::Find;
use Term::ANSIColor;
use Test::More;

use My::Base     qw(:all);
use My::File;
use My::UI;

use Sub::Exporter::Progressive -setup => {
  exports => [qw(cpuinfo linux_version pci_devs_by_class pci_ids pci_vga_devices)],
  groups => {
    default => [qw()],
    cpu => [qw(cpuinfo)],
    pci => [qw(pci_devs_by_class pci_ids pci_vga_devices)],
  },
};

sub cpuinfo {
  # each element of @cpus refers to a physical chip (and socket)
  # the array is therefore indexed by the 'physical id' field from /proc/cpuinfo
  my @cpus = ();
  open my $fh, '<', '/proc/cpuinfo';
  local $/ = "\n\n";
  while (my $chunk = <$fh>) {
    my $cpu = {};
    for my $line (split(/\n/, $chunk)) {
      $line =~ /(?<name>\w+(?:\s+\w+)*)\s*: (?<value>.+)/;
      $cpu->{$+{name}} = $+{value};
    }
    if (defined $cpus[$cpu->{'physical id'}]) {
      push @{$cpus[$cpu->{'physical id'}]{core_list}}, $cpu->{processor};
      next;
    }
    $cpus[$cpu->{'physical id'}] = {
      x64        => $cpu->{flags} =~ /\blm\b/,
      hvm        => $cpu->{flags} =~ /\b(vmx|svm)\b/,
      vendor     => $cpu->{vendor_id},
      flags      => $cpu->{flags},
      core_count => $cpu->{'cpu cores'},
      core_list  => [$cpu->{processor}],
      cache_size => $cpu->{'cache size'},
      model_name => $cpu->{'model name'},
      threads_per_core => int($cpu->{siblings} / $cpu->{'cpu cores'}),
      freq_max => slurp(
        '/sys/devices/system/cpu/cpu'.$cpu->{processor}.'/cpufreq/cpuinfo_max_freq'),
    };
  }
  return @cpus;
}

sub linux_version {
  assert_readable '/proc/version';
  my $build_string = slurp '/proc/version';
  $build_string =~
    /^Linux version (?<full>(?<version>\d+)(?:\.(?<patchlevel>\d+)(?:\.(?<sublevel>\d+))?)?(?<extraversion>[^\s]+)?)/
  or FATAL 'Failed to parse <b>/proc/version</b>: ', color('white'), $build_string;
  
  return {
    build        => $build_string,
    full         => $+{full},
    version      => $+{version},
    patchlevel   => $+{patchlevel},
    sublevel     => $+{sublevel},
    extraversion => $+{extraversion},
  };
}

sub pci_devs_by_class {
  @_ && $_[0] =~ $RE_HEX_BYTE or FATAL 'First argument is required';
  my $class    = shift;
  my $subclass = @_ && $_[0] =~ $RE_HEX_BYTE ? shift : undef;
  my $prog_if  = @_ && $_[0] =~ $RE_HEX_BYTE ? shift : undef;
  my $class_exp    = $class;
  my $subclass_exp = $RE_HEX_BYTE;
  my $progif_exp   = $RE_HEX_BYTE;
  my @host_bridges = glob('/sys/devices/pci[0-9a-f][0-9a-f][0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]');
  my @devs = ();
  my $result = \@devs;
  find({
      wanted => sub {
        push @devs, substr($_, 12) if
          not -l $_ and -f "${_}/class" and -f "${_}/vendor" and -f "${_}/device" and
          slurp({dochecks => 0}, "${_}/class") =~ /^(0?x)?${class_exp}${subclass_exp}${progif_exp}$/i;
      },
      no_chdir => 1
    },
    @host_bridges
  );
  return $result;
}

sub pci_ids {
  #   {
  #     [vendor_int] => {
  #       raw_id => [vendor_raw],
  #       id => [vendor_int],
  #       name => [vendor_name],
  #       devices => {
  #         [device_int] => {
  #           raw_id => [device_raw],
  #           id => [device_int],
  #           name => [device_name],
  #           subsystems => {
  #             [subdevice_int] => {
  #               vendor_raw_id => [subvendor_raw],
  #               vendor_id => [subvendor_int],
  #               device_raw_id => [subdevice_raw],
  #               device_id => [subdevice_int],
  #               name => [subsystem_name]
  #             }
  #           }
  #         },
  #         [device_int] => ...
  #       }
  #     },
  #     [vendor_int] => ...
  #   }
  # 
  # Vendor lookup:
  # $vendor = pci_ids->{hex('104a')};
  #
  # Device lookup:
  # $device = pci_ids->{hex('104a')}{devices}{hex('0010')};
  #
  # Subsystem device lookup:
  # $subsys_device = pci_ids->{hex('104a')}{devices}{hex('0010')}{subsystems}{@{[hex('1681'), hex('c010')]}};
  #
  # TODO:
  # - Add filter support to speed up process (vendor, vendor+device, vendor+device+subvendor, vendor+device+subvendor+subdevice)
  # - Multiple filter capability would be ideal so a list of devices to grab can be given
  #
  my $path = '/usr/share/hwdata/pci.ids';
  if (not -r $path) {
    $path = abs_path __DIR__ . '/../pci.ids';
    assert_readable $path;
  }
  #
  # pci_ids 'vid:did:svid:sdid' 'vid'
  #
  my $vendor_exp = '';
  my $device_exp = '';
  my $subvendor_exp = '';
  my $subdevice_exp = '';
  $vendor_exp = $RE_HEX_2BYTES; # or a dynamic list of 'vid1|vid2|vid3|...'
  $device_exp = $RE_HEX_2BYTES; # or a dynamic list generated at the end of vendor block (around undef $curr_device)
  $subvendor_exp = $RE_HEX_2BYTES; # or a dynamic list generated at the end of device block
  $subdevice_exp = $RE_HEX_2BYTES; # or a dynamic list generated at the end of device block 

  my %filter = (); # {vendor_exp => {device_exp => {subvendor_exp => [subdevice_exp]}}}
  if (@_) {
    for my $arg (@_) {
      my ($vid, $did, $svid, $sdid) = split /:/, $arg;

      if (defined $vid and $vid ne '' and $vid ne '*') {
        $vid = sprintf('%04x', hex($vid));
      } else {
        $vid = '*';
      }
      $filter{$vid} = () unless exists $filter{$vid};

      if (defined $did) {
        do { $filter{$vid} = '-'; next } if $did eq '-';
        $did = sprintf('%04x', hex($did)) if $did ne '' and $did ne '*';
      } else {
        $did = '*';
      }
      $filter{$vid}{$did} = () unless exists $filter{$vid}{$did};

      if (defined $svid) {
        do { $filter{$vid}{$did} = '-'; next } if $svid eq '-';
        $svid = sprintf('%04x', hex($svid)) if $svid ne '' and $svid ne '*';
      } else {
        $svid = '*';
      }
      $filter{$vid}{$did}{$svid} = () unless exists $filter{$vid}{$did}{$svid};

      if (defined $sdid and $sdid ne '' and $sdid ne '*') {
        push @{$filter{$vid}{$did}{$svid}}, sprintf('%04x', hex($sdid));
      } else {
        @{$filter{$vid}{$did}{$svid}} = ($RE_HEX_2BYTES);
      }
    }
  } else {
    $filter{'*'} = { '*' => { '*' => ('*'), }, };
  }
  #say Dumper(\%filter);
  #say Dumper(join '|', keys %filter);
  #say Dumper(exists($filter{'10de'}), join('|', keys %{$filter{'10de'}}));

  my %vendors = ();
  my $result = \%vendors;

  open my $fh, '<', $path;

#  {
#      $result->{string} = $line;
#
#      if ($line =~ /^(?<id>${RE_HEX_2BYTES})\s+(?<name>.*)\s*$/) {
#        $result->{type} = 'VENDOR';
#        $result->{id}   = $+{id};
#        $result->{name} = $+{name};
#      }
#      elsif ($line =~ /^\t(?<id>${RE_HEX_2BYTES})\s+(?<name>.*)\s*$/) {
#        $result->{type} = 'DEVICE';
#        $result->{id}   = $+{id};
#        $result->{name} = $+{name};
#      }
#      elsif ($line =~ /^\t\t(?<vid>${RE_HEX_2BYTES})\s+(?<did>${RE_HEX_2BYTES})\s+(?<name>.*)\s*$/) {
#        $result->{type} = 'SUBSYS';
#        $result->{vid}  = $+{vid};
#        $result->{did}  = $+{did};
#        $result->{name} = $+{name};
#      }
#      elsif ($line =~ /^C ${RE_HEX_BYTE}\s+/) {
#        $result->{type} = 'CLASS';
#      } else {
#        next;
#      }
#
#	  next if %wanted and not exists $wanted{$result->{type}};
#
  #    return $result;
  #  }
  #}

  my ($vendor, $device, $class, $subclass);

  my %wanted;
  @wanted{('VENDOR', 'CLASS')} = undef;
  while (my $line = <$fh>) {
    chomp $line;
    next unless length $line >= 6;
    my $hint = substr $line, 0, 2;
    # Class
    if (exists $wanted{'CLASS'} and $hint eq 'C ' 
      and substr($line, 2) =~ /^${RE_HEX_BYTE}\s/
    ) {
      delete $wanted{'VENDOR'};
      delete $wanted{'DEVICE'};
      delete $wanted{'SUBSYS'};
      last; # TODO: Remove and fix class parsing in future
      undef $vendor;
      undef $device;
      # $class = ...
      #print 'C';
      next;
    }
    # Subsystem (under device) or prog-if (under subclass)
    if ($hint eq "\t\t") {
      if (exists $wanted{'SUBSYS'} and $device 
        and $line =~ /^\t\t(?<vid>${RE_HEX_2BYTES})\s+(?<did>${RE_HEX_2BYTES})\s+(?<name>.*)\s*$/
      ) {
        $device->{subsystems}{$+{vid} . ':' . $+{did}} = {
          vendor_id => $+{vid},
          device_id => $+{did},
          supravendor_id => $vendor->{id},
          supradevice_id => $device->{id},
          name => $+{name},
        };
      } elsif (exists $wanted{'PROG-IF'} and $subclass) {
        # ...
      }
      next;
    }
    $hint = substr($line, 0, 1);
    # Device (under vendor) or subclass (under class)
    if ($hint eq "\t") {
      if (exists $wanted{'DEVICE'} and $vendor 
        and $line =~ /^\t(?<id>${RE_HEX_2BYTES})\s+(?<name>.*)\s*$/
      ) {
        delete $wanted{'SUBSYS'};
        if (%filter and exists $filter{$vendor->{id}}
          and not exists $filter{$vendor->{id}}{'*'} 
          and not exists $filter{$vendor->{id}}{$+{id}}) {
          next;
        }
        $wanted{'SUBSYS'} = undef unless %filter
          and exists $filter{$vendor->{id}}{'*'} && $filter{$vendor->{id}} eq '-'
          or exists $filter{$vendor->{id}}{$+{id}} && $filter{$vendor->{id}}{$+{id}} eq '-';
        $device = $vendor->{devices}{$+{id}} = {
          id => $+{id},
          vendor_id => $vendor->{id},
          name => $+{name},
          subsystems => exists $wanted{'SUBSYS'} ? {} : '-',
        };
      } elsif (exists $wanted{'SUBCLASS'} and $class) {
        # $subclass = ...
      }
      next;
    }
    # Vendor
    if (exists $wanted{'VENDOR'} and $hint ne '#' 
      and $line =~ /^(?<id>${RE_HEX_2BYTES})\s+(?<name>.*)\s*$/
    ) { # wanted = VENDOR, DEVICE, CLASS
      delete $wanted{'DEVICE'};
      delete $wanted{'SUBSYS'};
      if (%filter and not exists $filter{'*'} and not exists $filter{$+{id}}) {
        next;
      }
      $wanted{'DEVICE'} = undef unless %filter 
        and exists $filter{'*'} && $filter{'*'} eq '-'
        or exists $filter{$+{id}} && $filter{$+{id}} eq '-';
      $vendor = $vendors{$+{id}} = {
        id => $+{id},
        name => $+{name},
        devices => exists $wanted{'DEVICE'} ? {} : '-',
      };
      next;
    }
    # ? Unknown, implicit next
  }
  
  #$vendor_exp = join '|', keys %filter;
  #$l = $next->('VENDOR'); # Cue first vendor
  #while ($l and $l->{type} eq 'VENDOR') {
  #  $vendor = $vendors{$l->{id}} = {
  #    id => $l->{id},
  #    name => $l->{name},
  #    devices => {}
  #  };
  #  $l = $next->('DEVICE', 'VENDOR'); # Cue first device in vendor (or next vendor)
  #  while ($l and $l->{type} eq 'DEVICE') {
  #    $device = $vendor->{devices}{$l->{id}} = {
  #      id => $l->{id},
  #      vendor_id => $vendor->{id},
  #      name => $l->{name},
  #      subsystems => {}
  #    };
  #    $l = $next->('SUBSYS', 'DEVICE', 'VENDOR'); # Cue first subsystem in device (or next device, or vendor)
  #    while ($l and $l->{type} eq 'SUBSYS') {
  #      $device->{subsystems}{$l->{vid} . ':' . $l->{did}} = {
  #        vendor_id => $l->{vid},
  #        device_id => $l->{did},
  #        supravendor_id => $vendor->{id},
  #        supradevice_id => $device->{id},
  #        name => $l->{name}
  #      };
  #      $l = $next->('SUBSYS', 'DEVICE', 'VENDOR');
  #    }
  #  }
  #}

  return $result;
}

sub pci_vga_devices {
  my $pci_ids = pci_ids;
  my %vgadevs;
  my $result = \%vgadevs;
  @vgadevs{@{pci_devs_by_class '03', '00', '00'}} = ();
  while (my ($dev_addr) = each %vgadevs) {
    my $dev = $vgadevs{$dev_addr} = {};
    my $dev_sysfs = "/sys/devices${dev_addr}";
    $dev->{addr} = $dev_addr;
    $dev->{sysfs} = $dev_sysfs;
    $dev->{boot_vga} = int slurp "${dev_sysfs}/boot_vga";
    $dev->{driver_sysfs} = abs_path "${dev_sysfs}/driver";
    $dev->{driver} = basename $dev->{driver_sysfs};
    $dev->{iommu_sysfs} = abs_path "${dev_sysfs}/iommu";
    $dev->{iommu_group_sysfs} = abs_path "${dev_sysfs}/iommu_group";
    $dev->{iommu_group} = int basename $dev->{iommu_group_sysfs};
    ($dev->{vendor_raw_id} = slurp "${dev_sysfs}/vendor") =~ s/^(0x)//i;
    $dev->{vendor_id} = hex $dev->{vendor_raw_id};
    ($dev->{device_raw_id} = slurp "${dev_sysfs}/device") =~ s/^(0x)//i;
    $dev->{device_id} = hex $dev->{device_raw_id};
    ($dev->{subvendor_raw_id} = slurp "${dev_sysfs}/subsystem_vendor") =~ s/^(0x)//i;
    $dev->{subvendor_id} = hex $dev->{subvendor_raw_id};
    ($dev->{subdevice_raw_id} = slurp "${dev_sysfs}/subsystem_device") =~ s/^(0x)//i;
    $dev->{subdevice_id} = hex $dev->{subdevice_raw_id};
    my $vendor_info = $pci_ids->{$dev->{vendor_id}};
    my $device_info = $vendor_info->{devices}{$dev->{device_id}};
    $dev->{vendor_name} = $vendor_info->{name};
    $dev->{device_name} = $device_info->{name};
    $dev->{subvendor_name} = $pci_ids->{$dev->{subvendor_id}}{name};
    #$dev->{subsystem_name} = $device_info->{subsystems}{@{[$dev->{subvendor_id}, $dev->{subdevice_id}]}}{name} if 
    #  exists $device_info->{subsystems}{@{[$dev->{subvendor_id}, $dev->{subdevice_id}]}};
    $dev->{via} = []; # TODO parse middle section of $dev_addr into this

    # TODO this is all broken. just create a new string with host bridge and device (prefix and suffix) stripped,
    #      then work on that.
    my @dev_addr_parts = split m%/%, $dev_addr;
    say Dumper(\@dev_addr_parts);

    my ($host_bridge_addr) = $dev_addr =~ m%^(/[^/]+)%;
    $dev_addr = dirname $dev_addr;
    while (dirname $dev_addr ne $host_bridge_addr) {
      push @{$dev->{via}}, basename $dev_addr;
      $dev_addr = dirname $dev_addr; # WARNING THIS DESTROYS $dev_addr!!!
      say $dev_addr;exit;
    }
    #say Dumper($d);
  }
  return $result;
}

1;
