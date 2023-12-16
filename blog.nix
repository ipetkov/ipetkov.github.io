{ stdenv
, zola
}:

stdenv.mkDerivation {
  pname = "blog";
  version = "0.0.1";

  src = ./.;

  buildInputs = [ zola ];

  buildPhase = ''
    zola build -o $out
  '';
}
