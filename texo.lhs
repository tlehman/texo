---
title: 'texo: echo for \TeX{}'
author: "Tobi Lehman"
monofont: JuliaMono
---

The TeX typesetting system, created by Donald Knuth, became the standard way 
to format mathematical expressions on a computer. LaTeX is a macro language 
built on TeX that has a bunch of extra features that academics and researchers 
use. The `echo` command is a standard Unix command that outputs it's arguments, 
and if there are no arguments, it reads from the input pipe.

When I pipe `a_1x^2` through a pipeline, I want to *see* $a_1x^2$, not the ASCII
approximation of it. The `texo` command fixes that: it is `echo` for TeX
expressions.

This file is the entire program. It is a [literate Haskell](https://wiki.haskell.org/Literate_programming) file: every line
beginning with `>` is code, and everything else is prose. In addition to creating TeX, 
Knuth also introduced literate programming. GHC reads this file directly, 
so the "tangle" step of literate programming is
built into the compiler:

```sh
ghc -O2 texo.lhs -o texo     # tangle: prose is ignored, code is compiled
pandoc -f markdown+lhs texo.lhs --pdf-engine=xelatex -o texo.pdf   # weave: typeset the essay
```

The Haskell source code is generated (tangled) from this file, and the documentation 
is also generated (woven from this file).

The plan
========

`texo` reads one TeX expression from stdin and makes a single decision:

- if the terminal speaks the [kitty graphics
  protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/) and a TeX
  installation is on the `PATH`: render the expression to a PNG with
  `latex` and `dvipng`, and paint the image right into the terminal.
- otherwise: translate the expression to plain Unicode, so `a_1x^2`
  becomes `a₁x²`.

That is the whole program. In pictures:

```
stdin ──▶ kitty + latex available?
              │yes                │no
              ▼                   ▼
   latex ▶ dvipng ▶ base64     subscript/superscript
        ▼                      character tables
   kitty escape codes               │
              ▼                     ▼
           terminal ◀───────────────┘
```

Housekeeping
============

We only use libraries that ship with GHC: `base`, `bytestring`,
`directory`, `filepath`, and `process`. No package manager, no lock
file.

> module Main where
>
> import Control.Exception (SomeException, catch)
> import Data.Bits ((.&.), (.|.), shiftL, shiftR)
> import Data.Char (isAlpha, isSpace)
> import Data.List (dropWhileEnd, isInfixOf)
> import Data.Maybe (fromMaybe, isJust)
> import Data.Word (Word8)
> import qualified Data.ByteString as B
> import System.Directory (createDirectoryIfMissing, findExecutable, getTemporaryDirectory)
> import System.Environment (lookupEnv)
> import System.FilePath ((</>))
> import System.Process (readProcess)

The main event
==============

Read stdin, strip the trailing newline that `echo` adds, and take the
graphical path if we can. Rendering an image involves running two
external programs, and either can fail (a typo in the TeX, a broken
install). If anything at all goes wrong we fall back to the Unicode
translation, which cannot fail.

> main :: IO ()
> main = do
>   expr <- strip <$> getContents
>   let fallback :: SomeException -> IO ()
>       fallback _ = putStrLn (toUnicode expr)
>   graphical <- kittyReady
>   if graphical
>     then drawImage expr `catch` fallback
>     else putStrLn (toUnicode expr)
>
> strip :: String -> String
> strip = dropWhileEnd isSpace . dropWhile isSpace

How do we know the terminal can draw pixels? Kitty sets
`KITTY_WINDOW_ID` in its environment, and terminals that adopted the
same protocol (like Ghostty) advertise themselves in `TERM`. We also
insist that `latex` and `dvipng` actually exist before promising an
image.

> kittyReady :: IO Bool
> kittyReady = do
>   term   <- fromMaybe "" <$> lookupEnv "TERM"
>   window <- lookupEnv "KITTY_WINDOW_ID"
>   latex  <- findExecutable "latex"
>   dvipng <- findExecutable "dvipng"
>   let graphical = isJust window || any (`isInfixOf` term) ["kitty", "ghostty"]
>   pure (graphical && isJust latex && isJust dvipng)

Falling back to Unicode
=======================

Unicode has a small colony of subscript and superscript characters,
originally for phonetics and chemistry. They are scattered across
several blocks, so the clean way to reach them is a pair of lookup
tables: each table pairs a plain character with its shifted form. (A few
letters, like a subscript `b` or any form of `q`, simply do not exist in
Unicode. Those keep their plain shape rather than vanishing.)

> subscripts, superscripts :: [(Char, Char)]
> subscripts   = zip "0123456789+-=()aehijklmnoprstuvx"
>                    "₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₕᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓ"
> superscripts = zip "0123456789+-=()abcdefghijklmnoprstuvwxyz"
>                    "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ᵃᵇᶜᵈᵉᶠᵍʰⁱʲᵏˡᵐⁿᵒᵖʳˢᵗᵘᵛʷˣʸᶻ"

The translator walks the string one character at a time. Three
characters are special. An underscore shifts what follows down, a caret
shifts it up, and a backslash starts a control word. A control word is
one of two things: a *style* like `\mathbb`, which restyles the argument
that follows it, or a *symbol* like `\alpha`, which simply is a
character. Everything else passes through untouched.

> toUnicode :: String -> String
> toUnicode ('_' : s)  = script subscripts s
> toUnicode ('^' : s)  = script superscripts s
> toUnicode ('\\' : s) =
>   let (name, rest) = span isAlpha s
>   in case lookup name styles of
>        Just table -> script table (dropWhile isSpace rest)
>        Nothing    -> fromMaybe ('\\' : name) (lookup name symbols)
>                      ++ toUnicode rest
> toUnicode (c : s)    = c : toUnicode s
> toUnicode ""         = ""

In TeX, `_` and `^` grab exactly one character unless braces extend
their reach: `x_10` is $x_10$ but `x_{10}` is $x_{10}$. We honor the
same rule: with braces, shift the whole group; without, shift one
character.

> script :: [(Char, Char)] -> String -> String
> script table ('{' : s) = let (inside, rest) = break (== '}') s
>                          in map (shift table) inside ++ toUnicode (drop 1 rest)
> script table (c : s)   = shift table c : toUnicode s
> script _     ""        = ""
>
> shift :: [(Char, Char)] -> Char -> Char
> shift table c = fromMaybe c (lookup c table)

The symbol table covers the TeX control words with obvious Unicode
equivalents: the Greek alphabet and the everyday operators. It is a
plain association list, easy to extend by adding a line.

> symbols :: [(String, String)]
> symbols =
>   [ ("alpha", "α"), ("beta", "β"), ("gamma", "γ"), ("delta", "δ")
>   , ("epsilon", "ε"), ("zeta", "ζ"), ("eta", "η"), ("theta", "θ")
>   , ("iota", "ι"), ("kappa", "κ"), ("lambda", "λ"), ("mu", "μ")
>   , ("nu", "ν"), ("xi", "ξ"), ("pi", "π"), ("rho", "ρ")
>   , ("sigma", "σ"), ("tau", "τ"), ("upsilon", "υ"), ("phi", "φ")
>   , ("chi", "χ"), ("psi", "ψ"), ("omega", "ω")
>   , ("Gamma", "Γ"), ("Delta", "Δ"), ("Theta", "Θ"), ("Lambda", "Λ")
>   , ("Xi", "Ξ"), ("Pi", "Π"), ("Sigma", "Σ"), ("Phi", "Φ")
>   , ("Psi", "Ψ"), ("Omega", "Ω")
>   , ("infty", "∞"), ("partial", "∂"), ("nabla", "∇"), ("pm", "±")
>   , ("mp", "∓"), ("times", "×"), ("cdot", "·"), ("div", "÷")
>   , ("leq", "≤"), ("geq", "≥"), ("neq", "≠"), ("approx", "≈")
>   , ("equiv", "≡"), ("to", "→"), ("in", "∈"), ("subset", "⊂")
>   , ("cup", "∪"), ("cap", "∩"), ("forall", "∀"), ("exists", "∃")
>   , ("sum", "∑"), ("prod", "∏"), ("int", "∫"), ("sqrt", "√")
>   , ("cdots", "⋯"), ("ldots", "…")
>   ]

Styles are the pleasant surprise: `\mathbb{R}` takes an argument, just
like `_` and `^` do, so `script` already knows how to handle it. All a
style needs is its own character table, and Unicode obliges: it has an
entire "double-struck" alphabet for blackboard bold. The famous sets
(`ℂ`, `ℍ`, `ℕ`, `ℙ`, `ℚ`, `ℝ`, `ℤ`) were encoded early among the Letterlike Symbols,
and the rest of the alphabet arrived later in the Mathematical
Alphanumeric Symbols block, which is why the second string below jumps
between codepoint neighborhoods. Adding `\mathcal` or `\mathfrak` some
day means adding one table and one line here.

> styles :: [(String, [(Char, Char)])]
> styles = [ ("mathbb", blackboard) ]
>
> blackboard :: [(Char, Char)]
> blackboard = zip (['A'..'Z'] ++ ['a'..'z'] ++ ['0'..'9'])
>                  ("𝔸𝔹ℂ𝔻𝔼𝔽𝔾ℍ𝕀𝕁𝕂𝕃𝕄ℕ𝕆ℙℚℝ𝕊𝕋𝕌𝕍𝕎𝕏𝕐ℤ"
>                ++ "𝕒𝕓𝕔𝕕𝕖𝕗𝕘𝕙𝕚𝕛𝕜𝕝𝕞𝕟𝕠𝕡𝕢𝕣𝕤𝕥𝕦𝕧𝕨𝕩𝕪𝕫"
>                ++ "𝟘𝟙𝟚𝟛𝟜𝟝𝟞𝟟𝟠𝟡")

Rendering a real image
======================

When the terminal can draw pixels, we let TeX do what TeX does. We wrap
the expression in the smallest possible LaTeX document. `\pagestyle
{empty}` removes the page number, and `dvipng -T tight` later crops the
page down to the ink, so we need nothing fancier than the standard
`article` class plus `amssymb`, which defines `\mathbb` and a few
hundred symbols besides.

> document :: String -> String
> document expr = unlines
>   [ "\\documentclass{article}"
>   , "\\usepackage{amssymb}"
>   , "\\pagestyle{empty}"
>   , "\\begin{document}"
>   , "$" ++ expr ++ "$"
>   , "\\end{document}"
>   ]

The pipeline is `latex` (TeX source to DVI), then `dvipng` (DVI to a
tightly cropped PNG with a transparent background), then the kitty
escape codes. We run it in a scratch directory under the system temp
dir. `readProcess` raises an exception if either tool exits nonzero,
which is exactly what `main`'s fallback is waiting to catch.

> drawImage :: String -> IO ()
> drawImage expr = do
>   tmp <- (</> "texo") <$> getTemporaryDirectory
>   createDirectoryIfMissing True tmp
>   let tex = tmp </> "texo.tex"
>       dvi = tmp </> "texo.dvi"
>       png = tmp </> "texo.png"
>   writeFile tex (document expr)
>   _ <- readProcess "latex" [ "-interaction=batchmode"
>                            , "-output-directory=" ++ tmp, tex ] ""
>   _ <- readProcess "dvipng" [ "-q", "-D", "300", "-T", "tight"
>                             , "-bg", "Transparent", "-o", png, dvi ] ""
>   bytes <- B.unpack <$> B.readFile png
>   putStrLn (kittify (encode bytes))

Base64 in nine lines
--------------------

The kitty protocol wants the PNG as base64 text. Base64 is just a
regrouping: read the input three bytes ($3 \times 8 = 24$ bits) at a
time, deal those 24 bits out as four 6-bit numbers ($4 \times 6 = 24$),
and use each number to index a 64-character alphabet. When the input
runs out mid-group, `=` signs pad the output to a multiple of four. That
is small enough to write ourselves instead of pulling in a dependency.

> alphabet :: String
> alphabet = ['A'..'Z'] ++ ['a'..'z'] ++ ['0'..'9'] ++ "+/"
>
> encode :: [Word8] -> String
> encode (a : b : c : rest) =
>   pick [ n a `shiftR` 2
>        , (n a `shiftL` 4 .|. n b `shiftR` 4) .&. 63
>        , (n b `shiftL` 2 .|. n c `shiftR` 6) .&. 63
>        , n c .&. 63 ] ++ encode rest
> encode [a, b] = pick [ n a `shiftR` 2
>                      , (n a `shiftL` 4 .|. n b `shiftR` 4) .&. 63
>                      , n b `shiftL` 2 .&. 63 ] ++ "="
> encode [a]    = pick [ n a `shiftR` 2
>                      , n a `shiftL` 4 .&. 63 ] ++ "=="
> encode []     = ""
>
> n :: Word8 -> Int
> n = fromIntegral
>
> pick :: [Int] -> String
> pick = map (alphabet !!)

Speaking the kitty protocol
---------------------------

An image is transmitted as one or more escape-code packets of the form
`ESC _ G keys ; payload ESC \`, each payload at most 4096 bytes of
base64. The first packet carries the interesting keys: `f=100` means
"the payload is a PNG" and `a=T` means "transmit it and display it right
here". Every packet also says whether more are coming: `m=1` for "more"
and `m=0` for "this is the last one".

> kittify :: String -> String
> kittify b64 = go ("f=100,a=T," ++) (chunks 4096 b64)
>   where
>     go keys [c]      = packet (keys "m=0") c
>     go keys (c : cs) = packet (keys "m=1") c ++ go id cs
>     go _    []       = ""
>     packet keys payload = "\ESC_G" ++ keys ++ ";" ++ payload ++ "\ESC\\"
>
> chunks :: Int -> String -> [String]
> chunks _ "" = []
> chunks k s  = take k s : chunks k (drop k s)

Coda
====

That is all of `texo`: one decision, two character tables, a four-line
LaTeX document, base64 from first principles, and an escape-code
envelope. Around a hundred lines of Haskell, and the program you just
read is the program you run. The obvious next steps are more symbols in
the table and `\frac`-style constructions in the Unicode fallback; both
are additions to this essay, not to some other file.
