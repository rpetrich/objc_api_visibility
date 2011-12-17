#!/usr/bin/env perl
# objc_api_visibility.pl
#   by Ryan Petrich, inspired by Dustin Howett's Logos
# Reads all Objective-C method names from an installed SDK, determines their visibility and optionally compares against an iOS app binary

sub read_methods {
	my $cmd = shift;
	my $when_found = shift;
	my $current_class;
	open(LS_CMD, "$cmd |") or die "Can't run '$cmd'\n$!\n";
	while (<LS_CMD>) {
		my $line = $_;
		foreach my $statement (split(/;|(\/\/)|(\/\*)/, $line)) {
			if ($statement =~ /\G([+-])\s*\(\s*(.*?)\s*\)(?=\s*[\w:])/gc) {
				# Method definition
				my $return = $2;
				my @sel_parts = ();
				while ($statement =~ /\G\s*([\$\w]*)(\s*:\s*(\((.+?)\))?\s*([\$\w]+?)\b)?\s*(((__OSX_AVAILABLE)|(NS_DEPRECATED)|(NS_AVAILABLE)).*)?/gc) {
					# Read selector component
					push(@sel_parts, $1);
					last if !$2;
				}
				my $sel = join(':', @sel_parts);
				$when_found->($sel, $current_class);
			} elsif ($statement =~ /\@((interface)|(protocol))/) {
				# Class/Protocol definition
				my @components = split(/\s/, $_);
				$current_class = @components[1];
			} elsif ($statement =~ /\@property\s*\((.*)\).*?\s\*?(\S+)(\s*(__OSX|NS)_AVAILABLE.*)?\s*$/) {
				# Property definition
				my $getter = $2;
				if ($statement =~ /\@property\s*\(.*\).*?\(\^(\S*?)\)/) {
					# Fix some macro silliness
					$getter = $1;
				}
				my $setter;
				if ($getter =~ /^_/) {
					# Properties that begin with underscore are special cased
					$setter = substr $getter, 1;
					$setter = '_set' . ucfirst($setter) . ':';
				} else {
					$setter = 'set' . ucfirst($getter) . ':';
				}
				my $readable = 1;
				my $writable = 1;
				foreach my $attribute (split(/,\s*/, $1)) {
					# Parse attributes
					if ($attribute =~ /^readonly$/) {
						$writable = 0;
					} elsif ($attribute =~ /^writeonly$/) {
						$readable = 0;
					} elsif ($attribute =~ /^getter=(\S*)$/) {
						$getter = $1;
					} elsif ($attribute =~ /^setter=(\S*)$/) {
						$setter = $1;
					}
				}
				$when_found->($getter, $current_class) if $readable;
				$when_found->($setter, $current_class) if $writable;
			}
		}
	}
	close(LS_CMD);
}

# Find SDK path
my $xcode = `xcode-select -print-path`;
chomp $xcode;
my @paths = glob("$xcode/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS?.?.sdk");
die("Cannot find an iPhoneOS.platform SDK!\n") if scalar(@paths) == 0;
my $sdk_path = @paths[0];

# Build map of method names used in the SDK
my %method_map;
foreach my $binary(split("\0", `find "$sdk_path/System/Library" -maxdepth 4 -perm -111 -type f -print0`)) {
	# Class dump to find all methods
	read_methods "class-dump-z -N -N -y \"$sdk_path\" \"$binary\"", sub {
		# ...mark each as private and add class names
		my $method = shift;
		my $class_name = shift;
		%method_map->{$method}{'visibility'} = 'private';
		%method_map->{$method}{'classes'}{$class_name} = 1;
	}
}
foreach my $header(split("\0", `find "$sdk_path/System/Library/Frameworks" -name "*.h" -type f -print0`)) {
	# Find methods declared in headers
	read_methods "cat $header", sub {
		# ...mark each as public
		my $method = shift;
		%method_map->{$method}{'visibility'} = 'public';
	}
}

# Generate list of names to output
my @names_to_output;
if ($#ARGV == 0) {
	# Read selector table from the first argument
	my $method_table = `otool -s __TEXT __objc_methname "$ARGV[0]" | sed -n '3,\$p' | cut -c10-`;
	@names_to_output = split(/\x00/, scalar reverse (reverse unpack('(a4)*', pack('(H8)*', split(/\s+/, $method_table)))));
} else {
	# If no first argument, list all
	@names_to_output = keys %method_map;
}

# Ouput as TSV with the following fields visibility, method name, class names sorted by method name
foreach my $method(sort @names_to_output) {
	my $visibility = %method_map->{$method}{'visibility'};
	$visibility = 'new' if length($visibility) == 0;
	my $classes = join("\t", keys(%{ %method_map->{$method}{'classes'} }));
	print "$visibility\t$method\t$classes\n";
}
