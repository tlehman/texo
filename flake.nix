{
  description = "texo: echo for TeX and LaTeX expressions";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      eachSystem = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      texFor = pkgs: pkgs.texliveSmall.withPackages (ps: [ ps.dvipng ]);
    in
    {
      packages = eachSystem (pkgs: rec {
        texo = pkgs.stdenv.mkDerivation {
          pname = "texo";
          version = "0.2.0";
          src = ./.;

          nativeBuildInputs = [ pkgs.ghc pkgs.makeWrapper ];

          # Tangle: GHC compiles the literate program directly.
          buildPhase = ''
            ghc -O2 texo.lhs -o texo
          '';

          # latex and dvipng must be reachable at runtime for the image path.
          installPhase = ''
            install -Dm755 texo $out/bin/texo
            wrapProgram $out/bin/texo --prefix PATH : ${texFor pkgs}/bin
          '';

          meta = {
            description = "echo for TeX: Unicode or kitty-graphics rendering";
            mainProgram = "texo";
          };
        };
        default = texo;
      });

      devShells = eachSystem (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.ghc (texFor pkgs) pkgs.pandoc ];
        };
      });
    };
}
