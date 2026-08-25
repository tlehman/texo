# $\TeX\text{o}$ (pronounced like 'echo')

The `texo` command is like the `echo` command for $\TeX$ and $\LaTeX$ expressions.

## Example usage

If kitty graphics are not enabled in your terminal, the default behavior will be to translate the expression to unicode. For example:
 
```sh
% echo 'a_1x^2' | texo
a₁x²
```

Otherwise, the output will be an actual image of the expression, rendered in the terminal:


```sh
% echo 'a_1x^2' | texo
```
$a_1x^2$

## Building

The entire program is [`texo.lhs`](texo.lhs), a literate Haskell file. The prose is the documentation and the `>` lines are the source: GHC compiles the file directly (tangle), and pandoc typesets it (weave).

```sh
nix build                # tangle: ./result/bin/texo
echo '\pi r^2' | nix run . # or run it directly
```

For hacking, `nix develop` drops you into a shell with `ghc`, `latex`, `dvipng`, and `pandoc`, where:

```sh
ghc -O2 texo.lhs -o texo                      # tangle by hand
pandoc -f markdown+lhs texo.lhs \
  --pdf-engine=xelatex -o texo.pdf            # weave the essay
```

The weave needs xelatex because the source is full of Unicode that pdflatex can't handle. The `monofont: JuliaMono` line in the file's YAML header matters too: the source contains characters like `ₐ`, `ⁿ`, and `𝔸`, and [JuliaMono](https://juliamono.netlify.app/) is one of the few monospace fonts that has glyphs for all of them (`brew install --cask font-juliamono`).
