{ stdenv
, terminimal
, zola
}:

stdenv.mkDerivation {
  pname = "blog";
  version = "0.0.1";

  src = ./blog;

  buildInputs = [ zola ];

  configurePhase = ''
    mkdir -p themes
    ln -sn ${terminimal} themes/terminimal
  '';

  buildPhase = ''
    zola build
  '';

  installPhase = ''
    mv public $out
  '';
}
