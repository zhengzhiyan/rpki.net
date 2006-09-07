# $Id$

# Hack to generate a small test repository for testing Apache + OpenSSL + RPKI

use strict;

my %resources;
my %parent;
my @ordering;
my %hashes;

my $subdir	= "apacheca";
my $passwd	= "fnord";
my $keybits	= 2048;
my $verbose	= 0;

sub openssl {
    !system("openssl", @_)
	or die("openssl @_ returned $?\n");
}

# Ok, this is a bit complicated, but the idea is to let us specify the
# resources we're giving to each leaf entity and let the program do
# the work of figuring out what resources each issuers need to have,
# the order in which we need to generate the certificates, which
# certificates need to sign which other certificates, etcetera.
#
# This would be much easier to read in a sane language (eg, Scheme).

{
    my @ctx;
    my $loop ;
    $loop= sub {
	my $x = shift;
	if (ref($x) eq "HASH") {
	    while (my ($k, $v) = each(%$x)) {
		$parent{$k} = $ctx[@ctx - 1];
		push(@ordering, $k);
		push(@ctx, $k); $loop->($v); pop(@ctx);
	    }
	} else {
	    for my $c (@ctx) { push(@{$resources{$c}}, @$x) }
	}
    };
    $loop->({
	RIR => {
	    LIR1 => {
		ISP1 => [IPv4 => "10.0.1.1-10.0.3.255", AS => "33"],
		ISP2 => [IPv4 => "10.3.0.0-10.3.0.255"],
	    },
	    LIR2 => {
		ISP3 => [IPv6 => "2002::44-2002::100"],
		ISP4 => [IPv6 => "2002::10:0:44", AS => "44"],
	    },
	},
    });
}

# Put this stuff into a subdirectory

mkdir($subdir) unless (-d $subdir);
chdir($subdir) or die;

# Generate configurations for each entity.

while (my ($entity, $resources) = each(%resources)) {
    my %r;
    print($entity, ":\n")
	if ($verbose);
    for (my $i = 0; $i < @$resources; $i += 2) {
	printf("  %4s: %s\n", $resources->[$i], $resources->[$i+1])
	    if ($verbose);
	push(@{$r{$resources->[$i]}}, $resources->[$i+1]);
    }
    open(F, ">${entity}.cnf") or die;
    print(F
	  "[ req ]\n",
	  "default_bits = $keybits\n",
	  "encrypt_key = no\n",
	  "distinguished_name = req_dn\n",
	  "x509_extensions = req_x509_ext\n",
	  "prompt = no\n",
	  "\n",
	  "[ req_dn ]\n",
	  "\n",
	  "CN = TEST ENTITY $entity\n",
	  "\n",
	  "[ req_x509_ext ]\n",
	  "\n",
	  "basicConstraints = critical,CA:true\n",
	  "subjectKeyIdentifier = hash\n",
	  "authorityKeyIdentifier = keyid\n",
	  "keyUsage = critical,keyCertSign,cRLSign\n",
	  "subjectInfoAccess = 1.3.6.1.5.5.7.48.5;URI:rsync://wombats-r-us.hactrn.net/\n");
    print(F "authorityInfoAccess = caIssuers;URI:rsync://wombats-r-us.hactrn.net/$parent{$entity}.cer\n")
	if ($parent{$entity});
    print(F "sbgp-autonomousSysNum = critical,\@asid_ext\n")
	if ($r{AS} || $r{RDI});
    print(F "sbgp-ipAddrBlock = critical,\@addr_ext\n")
	if ($r{IPv4} || $r{IPv6});
    print(F "\n[ asid_ext ]\n\n");
    for my $n (qw(AS RDI)) {
	my $i = 0;
	for my $a (@{$r{$n}}) {
	    print(F $n, ".", $i++, " = ", $a, "\n");
	}
    }
    print(F "\n[ addr_ext ]\n\n");
    for my $n (qw(IPv4 IPv6)) {
	my $i = 0;
	for my $a (@{$r{$n}}) {
	    print(F $n, ".", $i++, " = ", $a, "\n");
	}
    }
    close(F);
}

# Run OpenSSL to create the keys and certificates.  We generate keys
# separately to avoid wasting /dev/random bits if we need to change
# the configuration.

for my $entity (@ordering) {
    openssl("genrsa", "-out", "${entity}.key", $keybits)
	unless (-f "${entity}.key");
    openssl("req", "-new", "-config", "${entity}.cnf", "-key", "${entity}.key", "-out", "${entity}.req");
    openssl("x509", "-req", "-CAcreateserial", "-in", "${entity}.req", "-out", "${entity}.cer",
	    "-extfile", "${entity}.cnf", "-extensions", "req_x509_ext",
	    ($parent{$entity}
	     ? ("-CA", "$parent{$entity}.cer", "-CAkey", "$parent{$entity}.key")
	     : ("-signkey", "${entity}.key")));
}

# Generate EE certs

for my $parent (@ordering) {
    my $entity = "${parent}-EE";
    open(F, ">${entity}.cnf") or die;
    print(F
	  "[ req ]\n",
	  "default_bits = $keybits\n",
	  "encrypt_key = no\n",
	  "distinguished_name = req_dn\n",
	  "x509_extensions = req_x509_ext\n",
	  "prompt = no\n",
	  "\n",
	  "[ req_dn ]\n",
	  "\n",
	  "CN = TEST ENDPOINT ENTITY ${entity}\n",
	  "\n",
	  "[ req_x509_ext ]\n",
	  "\n",
	  "basicConstraints = critical,CA:false\n",
	  "subjectKeyIdentifier = hash\n",
	  "authorityKeyIdentifier = keyid\n",
	  "subjectInfoAccess = 1.3.6.1.5.5.7.48.5;URI:rsync://wombats-r-us.hactrn.net/\n",
	  "authorityInfoAccess = caIssuers;URI:rsync://wombats-r-us.hactrn.net/$parent.cer\n",
	  "\n");
    close(F);
    openssl("genrsa", "-out", "${entity}.key", $keybits)
	unless (-f "${entity}.key");
    openssl("req", "-new", "-config", "${entity}.cnf", "-key", "${entity}.key", "-out", "${entity}.req");

    if (1) {

	if (!-f "${entity}.idx") {
	    open(F, ">${entity}.idx") or die;
	    close(F);
	}
	if (!-f "${entity}.srl") {
	    open(F, ">${entity}.srl") or die;
	    print(F "01\n") or die;
	    close(F);
	}

	# temporary hack, rewrite

	$ENV{NAME} = $entity;
	openssl(qw(ca -batch -verbose -config ../ca.cnf -extensions req_x509_ext),
		"-extfile", "${entity}.cnf", "-out", "${entity}.cer", "-in", "${entity}.req");

    } else {

	openssl("x509", "-req", "-CAcreateserial", "-in", "${entity}.req", "-out", "${entity}.cer",
		"-extfile", "${entity}.cnf", "-extensions", "req_x509_ext",
		"-CA", "${parent}.cer", "-CAkey", "${parent}.key");
    }
}

# We really ought to generate CRLs here too, but it'd be a pain,
# because that'd require us to use the ca command, which requires more
# of a database than the x509 commands above are generating.  Rewrite
# later if we really need this for some reason.

# Generate hashes

for my $cert (map({("$_.cer", "$_-EE.cer")} @ordering)) {
    my $hash = `openssl x509 -noout -hash -in $cert`;
    chomp($hash);
    $hash .= "." . (0 + $hashes{$hash}++);
    unlink($hash) if (-l $hash);
    symlink($cert, $hash)
	or die("Couldn't link $hash to $cert: $!\n");
}

# Generate PKCS12 forms of EE certificates
# -chain argument to pkcs12 requires certificate store, which we configure via an environment variable

$ENV{SSL_CERT_DIR} = do { my $pwd = `pwd`; chomp($pwd); $pwd; };

for my $ee (map({"$_-EE"} @ordering)) {
    my @cmd = ("pkcs12", "-export", "-in", "$ee.cer",  "-inkey", "$ee.key", "-password", "pass:$passwd");
    openssl(@cmd, "-out", "$ee.p12");
    openssl(@cmd, "-out", "$ee.chain.p12", "-chain");
}

# Finally, generate an unrelated self-signed certificate for the server

my $hostname = `hostname`;
chomp($hostname);
open(F, ">server.cnf") or die;
print(F
      "[ req ]\n",
      "default_bits = $keybits\n",
      "encrypt_key = no\n",
      "distinguished_name = req_dn\n",
      "prompt = no\n",
      "\n",
      "[ req_dn ]\n",
      "\n",
      "CN = $hostname\n",
      "\n");
close(F);
openssl(qw(genrsa -out server.key), $keybits)
    unless (-f "server.key");
openssl(qw(req -new -config server.cnf -key server.key -out server.req));
openssl(qw(x509 -req -CAcreateserial -in server.req -out server.cer -signkey server.key));

# Local Variables:
# compile-command: "perl generate-testrepo.pl"
# End:
