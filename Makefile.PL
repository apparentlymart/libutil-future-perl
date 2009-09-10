
use ExtUtils::MakeMaker;
WriteMakefile(
    'NAME' => 'Util::Future',
    'VERSION_FROM' => 'lib/Util/Future.pm',
    'PREREQ_PM'		=> {
    },
    ($] >= 5.005 ?
        (
            ABSTRACT_FROM => 'lib/Util/Future.pm',
            AUTHOR     => 'Martin Atkins <mart@degeneration.co.uk>'
        ) : ()
    ),
);
