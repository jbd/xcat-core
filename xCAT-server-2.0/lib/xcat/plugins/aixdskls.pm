#!/usr/bin/env perl
# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
#####################################################
#
#  xCAT plugin package to handle the mkdsklsnode & mkdsklsimage command.
#
#####################################################

package xCAT_plugin::aixdskls;

use xCAT::NodeRange;
use xCAT::Schema;
use xCAT::Utils;
use xCAT::DBobjUtils;
use Data::Dumper;
use Getopt::Long;
use xCAT::MsgUtils;
use strict;
use Socket;
use File::Path;

# options can be bundled up like -vV
Getopt::Long::Configure("bundling");
$Getopt::Long::ignorecase = 0;

#------------------------------------------------------------------------------

=head1    aixdskls

This program module file supports the mkdsklsnode & mkdsklsimage command.


=cut

#------------------------------------------------------------------------------

=head2    xCAT for AIX diskless support

=cut

#------------------------------------------------------------------------------

#----------------------------------------------------------------------------

=head3  handled_commands

        Return a list of commands handled by this plugin

=cut

#-----------------------------------------------------------------------------

sub handled_commands
{
    return {
            mkdsklsimage => "aixdskls",
            mkdsklsnode => "aixdskls"
            };
}


#----------------------------------------------------------------------------

=head3   process_request

        Check for xCAT command and call the appropriate subroutine.

        Arguments:

        Returns:
                0 - OK
                1 - error
        Globals:

        Error:

        Example:

        Comments:
=cut

#-----------------------------------------------------------------------------

sub process_request
{

    my $request  = shift;
    my $callback = shift;

    my $ret;
    my $msg;

    my $command  = $request->{command}->[0];
    $::args     = $request->{arg};
    $::filedata = $request->{stdin}->[0];

    # figure out which cmd and call the subroutine to process
    if ($command eq "mkdsklsnode")
    {
        ($ret, $msg) = &dsklsnode($callback);
    }
    elsif ($command eq "mkdsklsimage")
    {
        ($ret, $msg) = &dsklsimage($callback);
    }

	if ($ret > 0) {
		my $rsp;

		if ($msg) {
			push @{$rsp->{data}}, $msg;
		} else {
			push @{$rsp->{data}}, "Command returned an error.";
		}

		$rsp->{errorcode}->[0] = $ret;
		
		xCAT::MsgUtils->message("E", $rsp, $callback, $ret);

	}

	return 0;
}

#----------------------------------------------------------------------------

=head3   dsklsimage

        Support for the mkdsklsimage command.

		Creates an AIX/NIM diskless image - referred to as a SPOT or COSI.

        Arguments:
        Returns:
                0 - OK
                1 - error
        Globals:

        Error:

        Example:

        Comments:
=cut

#-----------------------------------------------------------------------------
sub dsklsimage
{
	my $callback = shift;

	@ARGV = @{$::args};

	# parse the options
	Getopt::Long::Configure("no_pass_through");
	if(!GetOptions(
		'f|force'	=> \$::FORCE,
		'h|help'     => \$::HELP,
		's=s'       => \$::opt_s,
		'l=s'       => \$::opt_l,
		'S=s'       => \$::opt_S,
		'verbose|V' => \$::VERBOSE,
		'v|version'  => \$::VERSION,))
	{

		&dsklsimage_usage($callback);
        return 1;
	}

	# display the usage if -h or --help is specified
    if ($::HELP) {
        &dsklsimage_usage($callback);
        return 0;
    }

	# display the version statement if -v or --verison is specified
    if ($::VERSION)
    {
        my $rsp;
        push @{$rsp->{data}}, "mkdsklsimage version 2.0\n";
        xCAT::MsgUtils->message("I", $rsp, $callback);
        return 0;
    }

	my $spot_name = shift @ARGV;
	# must have a source and a name
	if (!$::opt_s || !defined($spot_name) ) {
		my $rsp;
		push @{$rsp->{data}}, "The image source and image name are required.\n";
		xCAT::MsgUtils->message("E", $rsp, $callback);
		&dsklsimage_usage($callback);
		return 1;
	}

	#
	#  Get a list of the defined resources
	#
	my $cmd = qq~/usr/sbin/lsnim -c resources | /usr/bin/cut -f1 -d' ' 2>/dev/null~;
	my @output = xCAT::Utils->runcmd("$cmd", -1);
	if ($::RUNCMD_RC  != 0)
	{
		my $rsp;
        push @{$rsp->{data}}, "Could not get NIM resource definitions.";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
	}

	# if the source is not the name of an lpp_source then try to create one
	# we will need the lpp_source to update the image
	my $lppsrcname;
	my $buildlpp=0;
	if (-d $::opt_s) {
		# this is a source directory
		#    so see if we need to create a new lpp_source
		#	make a name using the convention and check if it already exists
		$lppsrcname= $spot_name . "_lpp";
		if (grep(/^$lppsrcname$/, @output)) {
			if ($::FORCE) {
				# get rid of the old lpp_source
				my $cmd = "/usr/sbin/nim -o remove $lppsrcname";
				my $out = xCAT::Utils->runcmd("$cmd", -1);
				if ($::RUNCMD_RC  != 0) {
					my $rsp;
					push @{$rsp->{data}}, "Could not run command \'$cmd\'. (rc = $::RUNCMD_RC)\n";
					xCAT::MsgUtils->message("E", $rsp, $callback);
					return 1;
				}

				# build a new one
				$buildlpp = 1;
			} else {
				my $rsp;
				push @{$rsp->{data}}, "The lpp_source (\'$lppsrcname\') for this COSI already exists. Use the force option to re-create it.\n";
				xCAT::MsgUtils->message("E", $rsp, $callback);
				return 1;
			}
		} else {
			$buildlpp = 1;
		}
	} else {
		# if not a dir then should be an existing lpp_source
		if (!(grep(/^$::opt_s$/, @output))) {
			my $rsp;
			push @{$rsp->{data}}, "\'$::opt_s\' is not a source directory or the name of a NIM lpp_source resource.\n";
			xCAT::MsgUtils->message("E", $rsp, $callback);
			&dsklsimage_usage($callback);
			return 1;
		} else {
			# ok this is the lpp_source to use
			$lppsrcname= $::opt_s
		}
	} 

	# build an lpp_source if needed
	if ($buildlpp) {
		my $rsp;
		push @{$rsp->{data}}, "Creating a NIM lpp_source resource called \'$lppsrcname\'.  This could take a while.\n";
		xCAT::MsgUtils->message("I", $rsp, $callback);

		my $cmd = "/usr/sbin/nim -o define -t lpp_source -a server=master -a location=/install/nim/lpp_source/$lppsrcname -a source=$::opt_s $lppsrcname";

		if ($::VERBOSE) {
			my $rsp;
			push @{$rsp->{data}}, "Running: \'$cmd\'\n";
			xCAT::MsgUtils->message("I", $rsp, $callback);
		}

		my $output = xCAT::Utils->runcmd("$cmd", -1);
        if ($::RUNCMD_RC  != 0)
        {
            my $rsp;
            push @{$rsp->{data}}, "Could not run command \'$cmd\'. (rc = $::RUNCMD_RC)\n";
            xCAT::MsgUtils->message("E", $rsp, $callback);
            return 1;
        }
	}

	# if the SPOT doesn't exist then create it
	if (!(grep(/^$spot_name$/, @output)) || $::FORCE) {

		#
		# Create the SPOT/COSI
		#
		my $mkcosi_cmd = "/usr/sbin/mkcosi ";

		# do we want verbose output?
		if ($::VERBOSE) {
			$mkcosi_cmd .= "-v ";
		}

		# source of images
		$mkcosi_cmd .= "-s $lppsrcname ";

		# where to put it - the default is /install
		if ($::opt_l) {
			$mkcosi_cmd .= "-l $::opt_l ";
		} else {
			$mkcosi_cmd .= "-l /install/nim/spot  ";
		}

		# what server do we want this created on? 
		#	- default is server I'm running this cmd on
		# !! might want to hide this for xCAT support??
		if ($::opt_S ) {
			$mkcosi_cmd .= "-S $::opt_S ";
		}

		# must have the name of the SPOT/COSI to create
		$mkcosi_cmd .= "$spot_name  2>&1";

		# run the cmd
		my $rsp;
		push @{$rsp->{data}}, "Creating a NIM SPOT resource. This could take a while.\n";
		xCAT::MsgUtils->message("I", $rsp, $callback);

		if ($::VERBOSE) {
            my $rsp;
            push @{$rsp->{data}}, "Running: \'$mkcosi_cmd\'\n";
            xCAT::MsgUtils->message("I", $rsp, $callback);
		}

		my $output = xCAT::Utils->runcmd("$mkcosi_cmd", -1);
		if ($::RUNCMD_RC  != 0)
		{
			my $rsp;
			push @{$rsp->{data}}, "Could not create a NIM definition for \'$spot_name\'.\n";
			xCAT::MsgUtils->message("E", $rsp, $callback);
			return 1;
		}

	} # end - if spot doesn't exist
	else {
		my $rsp;
		push @{$rsp->{data}}, "A SPOT called $spot_name already exists.\n";
		xCAT::MsgUtils->message("I", $rsp, $callback);
	}

	my $rsp;
	push @{$rsp->{data}}, "Updating $spot_name.\n";
	xCAT::MsgUtils->message("I", $rsp, $callback);

	#
	#  add rpm.rte to the SPOT 
	#	- it contains gunzip which is needed on the node
	#	- assume the source for the spot also has the rpm.rte fileset
	#
	if ($::VERBOSE) {
        my $rsp;
        push @{$rsp->{data}}, "Installing rpm.rte in the image.\n";
        xCAT::MsgUtils->message("I", $rsp, $callback);
    }

	my $cmd = "/usr/sbin/chcosi -i -s $::opt_s -f rpm.rte $spot_name";
	my $output = xCAT::Utils->runcmd("$cmd", -1);
	if ($::RUNCMD_RC  != 0)
	{
		my $rsp;
		push @{$rsp->{data}}, "Could not run command \'$cmd\'. (rc = $::RUNCMD_RC)\n";
		xCAT::MsgUtils->message("E", $rsp, $callback);
		return 1;
	}

	#
	#  Get the SPOT location ( path to ../usr)
	#
	$::spot_loc = &get_spot_loc($spot_name, $callback);
	if (!defined($::spot_loc) ) {
		my $rsp;
		push @{$rsp->{data}}, "Could not get the location of the SPOT/COSI named $::spot_loc.\n";
		xCAT::MsgUtils->message("E", $rsp, $callback);
		return 1;
	}

	#
	# Create ODMscript in the SPOT and modify the rc.dd-boot script
	#	- need for rnetboot to work - handles default console setting
	#
	my $odmscript = "$::spot_loc/ODMscript";
	if ($::VERBOSE) {
        my $rsp;
        push @{$rsp->{data}}, "Adding $odmscript to the image.\n";
        xCAT::MsgUtils->message("I", $rsp, $callback);
    }

	#  Create ODMscript script
	my $text = "CuAt:\n\tname = sys0\n\tattribute = syscons\n\tvalue = /dev/vty0\n\ttype = R\n\tgeneric =\n\trep = s\n\tnls_index = 0";

	if ( open(ODMSCRIPT, ">$odmscript") ) {
		print ODMSCRIPT $text;
		close(ODMSCRIPT);
	} else {
		my $rsp;
		push @{$rsp->{data}}, "Could not open $odmscript for writing.\n";
		xCAT::MsgUtils->message("E", $rsp, $callback);
		return 1;
	}
	my $cmd = "chmod 444 $odmscript";
	my @result = xCAT::Utils->runcmd("$cmd", -1);
	if ($::RUNCMD_RC  != 0)
	{
		my $rsp;
		push @{$rsp->{data}}, "Could not run the chmod command.\n";
		xCAT::MsgUtils->message("E", $rsp, $callback);
		return 1;
	}

	# Modify the rc.dd-boot script to set the ODM correctly
	my $boot_file = "$::spot_loc/lib/boot/network/rc.dd_boot";
	if (&update_dd_boot($boot_file, $callback) != 0) {
		my $rsp;
		push @{$rsp->{data}}, "Could not update the rc.dd_boot file in the SPOT.\n";
		xCAT::MsgUtils->message("E", $rsp, $callback);
		return 1;
	}

	#
	# Copy the xcatdsklspost script to the SPOT/COSI and add an entry for it
	#	to the /etc/inittab file
	#
	if ($::VERBOSE) {
		my $rsp;
		push @{$rsp->{data}}, "Adding xcatdsklspost script to the image.\n";
		xCAT::MsgUtils->message("I", $rsp, $callback);
	}

	# copy the script
	my $cpcmd = "mkdir -m 644 -p $::spot_loc/lpp/bos/inst_root/opt/xcat; cp /install/postscripts/xcatdsklspost $::spot_loc/lpp/bos/inst_root/opt/xcat/xcatdsklspost";

	if ($::VERBOSE) {
		my $rsp;
		push @{$rsp->{data}}, "Running: \'$cpcmd\'\n";
		xCAT::MsgUtils->message("I", $rsp, $callback);
	}

	my @result = xCAT::Utils->runcmd("$cpcmd", -1);
	if ($::RUNCMD_RC  != 0)
	{
		my $rsp;
        push @{$rsp->{data}}, "Could not copy the xcatdsklspost script to the SPOT.\n";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
    }	

	# add an entry to the /etc/inittab file in the COSI/SPOT
	if (&update_inittab($callback) != 0) {
		my $rsp;
        push @{$rsp->{data}}, "Could not update the /etc/inittab file in the SPOT.\n";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
	}

	#
	# Output results
	#
	# - use lsnim or nim -o showres  ??
	my $rsp;
	push @{$rsp->{data}}, "A diskless image called $spot_name was created and/or updated.\n";
	xCAT::MsgUtils->message("I", $rsp, $callback);

	return 0;

} # end dsklsimage


#-------------------------------------------------------------------------

=head3   update_inittab  
		 - add an entry for xcatdsklspost to /etc/inittab    
                                                                         
   Description:  This function updates the /etc/inittab file. 
                                                                         
   Arguments:    None.                                                   
                                                                         
   Return Codes: 0 - All was successful.                                 
                 1 - An error occured.                                   
=cut

#------------------------------------------------------------------------
sub update_inittab
{
	my $callback = shift;
    my ($cmd, $rc, $entry);

	my $spotinittab = "$::spot_loc/lpp/bos/inst_root/etc/inittab";

	my $entry = "xcat:2:wait:/opt/xcat/xcatdsklspost\n";

	# see if xcatdsklspost is already in the file
	my $cmd = "cat $spotinittab | grep xcatdsklspost";
	my @result = xCAT::Utils->runcmd("$cmd", -1);
    if ($::RUNCMD_RC == 0)
    {
		# it's already there so return
		return 0;
    }

	unless (open(INITTAB, ">>$spotinittab")) {
		my $rsp;
		push @{$rsp->{data}}, "Could not open $spotinittab for appending.\n";
		xCAT::MsgUtils->message("E", $rsp, $callback);
		return 1;
	}

	print INITTAB $entry;

	close (INITTAB);

	return 0;
}

#----------------------------------------------------------------------------

=head3  get_spot_loc

        Use the lsnim command to find the location of a spot resource.

        Arguments:
        Returns:
                0 - OK
                1 - error
        Globals:

        Error:

        Example:

        Comments:
=cut

#-----------------------------------------------------------------------------
sub get_spot_loc {

	my $spotname = shift;
	my $callback = shift;

	my $cmd = "/usr/sbin/lsnim -l $spotname";

	my @result = xCAT::Utils->runcmd("$cmd", -1);
    if ($::RUNCMD_RC  != 0)
    {
		my $rsp;
        push @{$rsp->{data}}, "Could not run lsnim command.\n";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
    }

	foreach (@result){
		my ($attr,$value) = split('=');
		chomp $attr;
		$attr =~ s/\s*//g;  # remove blanks
		chomp $value;
		$value =~ s/\s*//g;  # remove blanks
		if ($attr eq 'location') {
			return $value;
		}
	}
	return undef;
}

#----------------------------------------------------------------------------

=head3   update_dd_boot

         Add the workaround for the default console to rc.dd_boot.

        Arguments:
        Returns:
                0 - OK
                1 - error
        Globals:

        Error:

        Example:

        Comments:
=cut

#-----------------------------------------------------------------------------
sub update_dd_boot {

	my $dd_boot_file = shift;
	my $callback = shift;

	my @lines;
	my $patch = qq~\n\t# xCAT support\n\tif [ -z "\$(odmget -qattribute=syscons CuAt)" ] \n\tthen\n\t  \${SHOWLED} 0x911\n\t  cp /usr/ODMscript /tmp/ODMscript\n\t  [ \$? -eq 0 ] && odmadd /tmp/ODMscript\n\tfi \n\n~;

	# back up the original file
	my $cmd    = "cp -f $dd_boot_file $dd_boot_file.orig";
 	my $output = xCAT::Utils->runcmd("$cmd", -1);
	if ($::RUNCMD_RC  != 0)
	{
		my $rsp;
        push @{$rsp->{data}}, "Could not copy $dd_boot_file.\n";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
	}
	
	if ( open(DDBOOT, "<$dd_boot_file") ) {
		@lines = <DDBOOT>;
		close(DDBOOT);
	} else {
		my $rsp;
        push @{$rsp->{data}}, "Could not open $dd_boot_file for reading.\n";
        xCAT::MsgUtils->message("E", $rsp, $callback);
		return 1;
	}

	# remove the file
	my $cmd    = "rm $dd_boot_file";
	my $output = xCAT::Utils->runcmd("$cmd", -1);
	if ($::RUNCMD_RC  != 0)
    {
		my $rsp;
        push @{$rsp->{data}}, "Could not remove original $dd_boot_file.\n";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
    }

	# Create a new one
	my $dontupdate=0;
	if ( open(DDBOOT, ">$dd_boot_file") ) {
		foreach my $l (@lines)
		{
			if ($l =~ /xCAT support/) {
				$dontupdate=1;
			}

			if ( ($l =~ /0x620/) && (!$dontupdate) ){
				# add the patch
				print DDBOOT $patch;
			}
			print DDBOOT $l;
		}
		close(DDBOOT);

	} else {
		my $rsp;
        push @{$rsp->{data}}, "Could not open $dd_boot_file for writing.\n";
        xCAT::MsgUtils->message("E", $rsp, $callback);
		return 1;
    }

	if ($::VERBOSE) {
		my $rsp;
        push @{$rsp->{data}}, "Updated $dd_boot_file.\n";
        xCAT::MsgUtils->message("I", $rsp, $callback);
	}
	return 0;
}

#----------------------------------------------------------------------------

=head3   dsklsnode

        Support for the mkdsklsnode command.

        Arguments:
        Returns:
                0 - OK
                1 - error
        Globals:

        Error:

        Example:

        Comments:
=cut

#-----------------------------------------------------------------------------
sub dsklsnode 
{
	my $callback = shift;

	# some subroutines require a global callback var
	#	- need to change to pass in the callback 
	#	- just set global for now
    $::callback=$callback;

	@ARGV = @{$::args};

	# parse the options
	if(!GetOptions(
		'f|force'	=> \$::FORCE,
		'h|help'     => \$::HELP,
		'c=s'       => \$::opt_c,
		'verbose|V' => \$::VERBOSE,
		'v|version'  => \$::VERSION,))
	{
		&dsklsnode_usage($callback);
		return 1;
	}

	if ($::HELP) {
		&dsklsnode_usage($callback);
		return 0;
	}

	# display the version statement if -v or --verison is specified
    if ($::VERSION)
    {
        my $rsp;
        push @{$rsp->{data}}, "mkdsklsnode version 2.0\n";
        xCAT::MsgUtils->message("I", $rsp, $callback);
        return 0;
    }

	my $a = shift @ARGV;
	unless ($a) {
		return 1;
	}
	my @nodelist = &noderange($a, 0);
	my %objtype;
	my %objhash;

	# get the node defs
	# get all the attrs for these definitions
	foreach my $o (@nodelist)
	{
		push(@::clobjnames, $o);
		$objtype{$o} = 'node';
	}

	%objhash = xCAT::DBobjUtils->getobjdefs(\%objtype,$callback);
	if (!defined(%objhash))
	{
		my $rsp;
		push @{$rsp->{data}}, "Could not get xCAT object definitions.\n";
	    xCAT::MsgUtils->message("E", $rsp, $callback);
    	return 1;
	}

	#Get the network info for each node
	my %nethash = xCAT::DBobjUtils->getNetwkInfo(\@nodelist, $callback);
	if (!defined(%nethash))
	{
		my $rsp;
		push @{$rsp->{data}}, "Could not get xCAT network definitions for one or more nodes.\n";
		xCAT::MsgUtils->message("E", $rsp, $callback);
		return 1;
	}

	#
    #  Get a list of the defined machines
    #
    my $cmd = qq~/usr/sbin/lsnim -c machines | /usr/bin/cut -f1 -d' ' 2>/dev/nu
ll~;
    my @machines = xCAT::Utils->runcmd("$cmd", -1);
    if ($::RUNCMD_RC  != 0)
    {
        my $rsp;
        push @{$rsp->{data}}, "Could not get NIM machine definitions.";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
    }
	#
    #  Get a list of the defined diskless machines
    #
    my $cmd = qq~/usr/sbin/lsnim -t diskless | /usr/bin/cut -f1 -d' ' 2>/dev/nu
ll~;
    my @dsklsnodes = xCAT::Utils->runcmd("$cmd", -1);
    if ($::RUNCMD_RC  != 0)
    {
        my $rsp;
        push @{$rsp->{data}}, "Could not get NIM diskless definitions.";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
    }

	my $error=0;

	foreach my $node (keys %objhash)
	{

		# need short host name for NIM cmds
        my $shorthost;
        ($shorthost = $node) =~ s/\..*$//;
        chomp $shorthost;

		# does it already exist??
		if (grep(/^$shorthost$/, @machines)) { # already defined
			if ($::FORCE) {
				# get rid of the old definition
				if (grep(/^$shorthost$/, @dsklsnodes)) { 
					# remove the diskless node - run rmts
					my $rmtscmd = "rmts -f $shorthost";
					my $output = xCAT::Utils->runcmd("$rmtscmd", -1);
					if ($::RUNCMD_RC  != 0) {
						my $rsp;
						push @{$rsp->{data}}, "Could not remove $node.\n";
						if ($::VERBOSE) {
							push @{$rsp->{data}}, "$output";
						}
						xCAT::MsgUtils->message("E", $rsp, $callback);
						$error++;
						next;
					}

				} else { # just remove the machine def
					my $rmcmd = "nim -o remove $shorthost";
					my $output = xCAT::Utils->runcmd("$rmcmd", -1);
                    if ($::RUNCMD_RC  != 0) {
                        my $rsp;
                        push @{$rsp->{data}}, "Could not remove $node.\n";
                        if ($::VERBOSE) {
                            push @{$rsp->{data}}, "$output";
                        }
                        xCAT::MsgUtils->message("E", $rsp, $callback);
                        $error++;
                        next;
                    }

				}
			} elsif ($::opt_w) {
				# switch to the new image
				# nim -Fo reset $node
				# nim -Fo deallocate -a subclass=all $node
				# nim -o dkls_init ..... $node
				#	- does a sync_root
				# TBD
				next;

			} else {
				my $rsp;
				push @{$rsp->{data}}, "The node $node is already defined. Use the force option to re-create.";
				xCAT::MsgUtils->message("E", $rsp, $callback);
				$error++;
				next;
			}


		} else {  # not defined - so define it!

        	# get, check the node IP
        	my $IP = inet_ntoa(inet_aton($node));
        	chomp $IP;
        	unless ($IP =~ /\d+\.\d+\.\d+\.\d+/)
        	{
				my $rsp;
				push @{$rsp->{data}}, "Could not get valid IP address for node $node.\n";
				xCAT::MsgUtils->message("E", $rsp, $callback);
				$error++;
				next;
        	}

			#
			#  Create a unique post script
			#	- this routine should handle a noderange to be more efficient!
			#
			mkpath "/install/postscripts/";
			xCAT::Postage->writescript($node, "/install/postscripts/".$node, "netboot", $callback);

			#
			#  Run the AIX mkts cmd to define and initialize a diskless client
			#
        	my $cosi = $::opt_c;
        	my $cmd = qq~mkts -i $IP -m $nethash{$node}{'mask'} -g $nethash{$node}{'gateway'} -c $cosi -l $shorthost 2>&1~;

			my $rsp;
			push @{$rsp->{data}}, "Creating NIM diskless node definition. This could take a while.\n";
			xCAT::MsgUtils->message("I", $rsp, $callback);

			if ($::VERBOSE) {
            	my $rsp;
            	push @{$rsp->{data}}, "Running: \'$cmd\'\n";
            	xCAT::MsgUtils->message("I", $rsp, $callback);
        	}

        	my $output = xCAT::Utils->runcmd("$cmd", -1);
        	if ($::RUNCMD_RC  != 0)
        	{
				my $rsp;
				push @{$rsp->{data}}, "Could not create a NIM definition for \'$node\'.\n";
				if ($::VERBOSE) {
					push @{$rsp->{data}}, "$output";
	    		}
				xCAT::MsgUtils->message("E", $rsp, $callback);
				$error++;
				next;
        	}
		}
	}

	my $rc = xCAT::Utils->create_postscripts_tar();
	if ( $rc != 0 ) {
		my $rsp;
		push @{$rsp->{data}}, "Could not create a post scripts tar file.\n";
		xCAT::MsgUtils->message("E", $rsp, $callback);
		return 1;
	}

	if ($error) {
		my $rsp;
		push @{$rsp->{data}}, "One or more errors occurred when attempting to initialize AIX NIM diskless nodes.\n";
		xCAT::MsgUtils->message("E", $rsp, $callback);
		return 1;
	} else {
		my $rsp;
		push @{$rsp->{data}}, "AIX NIM diskless nodes were initialized.\n";
		xCAT::MsgUtils->message("I", $rsp, $callback);
		return 0;
	}
}

#----------------------------------------------------------------------------

=head3  dsklsnode_usage

        Arguments:
        Returns:
        Globals:

        Error:

        Example:

        Comments:
=cut

#-----------------------------------------------------------------------------

sub dsklsnode_usage
{
	my $callback = shift;

	my $rsp;
	push @{$rsp->{data}}, "  mkdsklsnode - Create an AIX NIM diskless node using information from the xCAT database.\n";
	push @{$rsp->{data}}, "  Usage: ";
	push @{$rsp->{data}}, "\tmkdsklsnode [-h | --help ]";
	push @{$rsp->{data}}, "or";
	push @{$rsp->{data}}, "\tmkdsklsnode [-V] [-f | --force] -c cosi_name noderange";
	xCAT::MsgUtils->message("I", $rsp, $callback);
    return 0;
}
#----------------------------------------------------------------------------

=head3  dsklsimage_usage

        Arguments:
        Returns:
        Globals:

        Error:

        Example:

        Comments:
=cut

#-----------------------------------------------------------------------------

sub dsklsimage_usage
{
	my $callback = shift;

	my $rsp;
    push @{$rsp->{data}}, "  mkdsklsimage - Create an AIX NIM diskless image (SPOT/COSI).\n";
    push @{$rsp->{data}}, "  Usage: ";
    push @{$rsp->{data}}, "\tmkdsklsimage [-h | --help]";
    push @{$rsp->{data}}, "or";
    push @{$rsp->{data}}, "\tmkdsklsimage [-V] [-f | --force] [-l <location>] -s <image_source> image_name\n";
    xCAT::MsgUtils->message("I", $rsp, $callback);
    return 0;
}

1;
