use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
	      'DISTNAME'  => 'Games-Rezrov',
	      'NAME'	=> 'Games::Rezrov::ZInterpreter',
	      'VERSION_FROM' => 'rezrov',
	      'EXE_FILES' => [ 'rezrov' ],
	      'dist' => {
			 "ZIPFLAGS" => "-r9",
			 'COMPRESS' => 'gzip -f9',
			},
);
