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

Here's how to use this literate Haskell program:
```sh
make tangle  # tangle: prose is ignored, code is compiled
make weave   # weave: typeset the essay
```

The Haskell source code is generated (tangled) from this file, and the documentation 
is also generated (woven from this file).

The plan
========

`texo` takes one TeX expression, from its arguments or from stdin, and
renders it one of two ways. The user picks with a flag:

- `-k`/`--kitty`: render the expression to a PNG with `latex` and
  `dvipng`, and paint the image right into the terminal via the [kitty
  graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/).
- `-u`/`--unicode` (the default): translate the expression to plain
  Unicode, so `a_1x^2` becomes `a₁x²`.

That is the whole program. In pictures:

```
input ──▶ which flag?
              │-k                 │-u (default)
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
> import Control.Exception (IOException, catch)
> import Data.Bits ((.&.), (.|.), shiftL, shiftR)
> import Data.Char (isAlpha, isHexDigit, isSpace)
> import Data.List (dropWhileEnd, isPrefixOf)
> import Data.Maybe (fromMaybe)
> import Data.Word (Word8)
> import Numeric (readHex)
> import qualified Data.ByteString as B
> import System.Directory (createDirectoryIfMissing, getTemporaryDirectory)
> import System.Environment (getArgs)
> import System.FilePath ((</>))
> import System.IO (BufferMode (LineBuffering, NoBuffering), Handle,
>                   IOMode (ReadWriteMode), hFlush, hGetChar, hPutStr,
>                   hSetBuffering, hSetEcho, hWaitForInput, withFile)
> import System.Process (readProcess)

The main event
==============

`echo` prints its arguments, and only reads stdin when there are none.
`texo` honors the same contract: `texo 'a_1x^2'` takes the expression
straight from the command line, joining multiple arguments with spaces
just as `echo` would, and a bare `texo` still reads the pipe. Every
respectable command also answers two questions about itself, so before
any TeX is looked at we intercept `--help` and `--version`.

> version :: String
> version = "0.4.0"
>
> usage :: String
> usage = unlines
>   [ "texo " ++ version ++ ": echo for TeX expressions"
>   , ""
>   , "usage: texo [-u|-k] [EXPRESSION]"
>   , ""
>   , "  --unicode, -u   translate to Unicode (the default)"
>   , "  --kitty,   -k   render an image via the kitty graphics protocol"
>   , "  --help,    -h   show this message"
>   , "  --version, -v   show the version"
>   , ""
>   , "With no EXPRESSION, texo reads one from stdin."
>   ]

Guessing what a terminal can draw is a losing game: `TERM` lies,
multiplexers strip environment variables, and pipes have no opinions.
So `texo` does not guess. The user says `-k`/`--kitty` for the graphical
path or `-u`/`--unicode` for the translation, and with no flag the
translation wins, because it works everywhere. The flags are picked out
of the argument list before the remainder is treated as the expression.

> data Mode = Unicode | Kitty
>
> parseMode :: [String] -> (Mode, [String])
> parseMode = foldr flag (Unicode, [])
>   where
>     flag a (m, rest)
>       | a `elem` ["--unicode", "-u"] = (Unicode, rest)
>       | a `elem` ["--kitty", "-k"]   = (Kitty, rest)
>       | otherwise                    = (m, a : rest)

Whichever way the expression arrives, we strip surrounding whitespace
(like the trailing newline that `echo` adds). Rendering an image runs
two external programs, and either can fail (a typo in the TeX, a broken
install). There is no safety net: the user asked for an image, so a
failure should be seen, not papered over with Unicode.

> main :: IO ()
> main = do
>   args <- getArgs
>   case args of
>     [a] | a `elem` ["--help", "-h"]    -> putStr usage
>         | a `elem` ["--version", "-v"] -> putStrLn ("texo " ++ version)
>     _ -> do
>       let (mode, rest) = parseMode args
>       expr <- strip <$> if null rest then getContents else pure (unwords rest)
>       case mode of
>         Unicode -> putStrLn (toUnicode expr)
>         Kitty   -> drawImage expr
>
> strip :: String -> String
> strip = dropWhileEnd isSpace . dropWhile isSpace

Translating to Unicode
======================

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

When the user asks for pixels, we let TeX do what TeX does. We wrap
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

Matching the terminal's ink
---------------------------

There is a trap here: `dvipng` paints black ink by default, and black
ink on a dark terminal is invisible. Guessing the theme from environment
variables is the same losing game as guessing graphics support, so
again we refuse to guess. We ask. Terminals have answered this exact
question since xterm: the escape code `ESC ] 10 ; ? BEL` (an
["operating system command"](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h3-Operating-System-Commands "xterm control sequences: Operating System Commands"),
OSC 10) means "what color is your text?", and the terminal writes its
answer back on the input stream, something like `rgb:e6e6/e6e6/e6e6`.
If we hand that exact color to `dvipng`, the math is set in the same
ink as everything else on the screen, whatever the theme.

The conversation has to happen on `/dev/tty`, not stdout, because
stdout may be a pipe. We turn off line buffering (which, on a terminal,
also turns off line *editing*, so the reply arrives byte by byte) and
echo (so the reply is not splattered across the screen), send the
question, and collect the answer until its terminator. A terminal that
stays silent for 200 milliseconds is never going to answer, and any
failure at all, including there being no terminal, falls back to black,
the old behavior.

> foreground :: IO (Maybe String)
> foreground = ask `catch` \e -> pure (const Nothing (e :: IOException))
>   where
>     ask = withFile "/dev/tty" ReadWriteMode $ \tty -> do
>       hSetBuffering tty NoBuffering
>       hSetEcho tty False
>       hPutStr tty "\ESC]10;?\a"
>       hFlush tty
>       reply <- collect tty (64 :: Int)
>       hSetEcho tty True
>       hSetBuffering tty LineBuffering
>       pure (inkColor reply)
>     collect _ 0 = pure ""
>     collect tty k = do
>       ready <- hWaitForInput tty 200
>       if not ready then pure "" else do
>         c <- hGetChar tty
>         if c `elem` "\a\\" then pure ""
>                            else (c :) <$> collect tty (k - 1)

The reply's channels are hexadecimal, and their width varies by
terminal: some say `ff`, some say `ffff`. Dividing by $16^n - 1$ maps
both spellings of full brightness to exactly $1.0$, which suits
`dvipng`: its color language takes `rgb r g b` with each channel
between 0 and 1.

> inkColor :: String -> Maybe String
> inkColor reply = do
>   spec <- after "rgb:" reply
>   case traverse channel (splitOn '/' spec) of
>     Just [r, g, b] -> Just (unwords ("rgb" : map show [r, g, b]))
>     _              -> Nothing
>
> channel :: String -> Maybe Double
> channel s = case readHex hex of
>     [(v, "")] | not (null hex) ->
>       Just (fromIntegral (v :: Integer) / (16 ^ length hex - 1))
>     _ -> Nothing
>   where hex = takeWhile isHexDigit s
>
> after :: String -> String -> Maybe String
> after pat s
>   | pat `isPrefixOf` s = Just (drop (length pat) s)
> after pat (_ : t)      = after pat t
> after _   ""           = Nothing
>
> splitOn :: Char -> String -> [String]
> splitOn d s = case break (== d) s of
>   (a, _ : rest) -> a : splitOn d rest
>   (a, "")       -> [a]

The pipeline is `latex` (TeX source to DVI), then `dvipng` (DVI to a
tightly cropped PNG with a transparent background, its ink matched to
the terminal's), then the kitty escape codes. We run it in a scratch directory under the system temp
dir. `readProcess` raises an exception if either tool exits nonzero,
so a broken render surfaces as an error instead of a blank line.

> drawImage :: String -> IO ()
> drawImage expr = do
>   tmp <- (</> "texo") <$> getTemporaryDirectory
>   createDirectoryIfMissing True tmp
>   let tex = tmp </> "texo.tex"
>       dvi = tmp </> "texo.dvi"
>       png = tmp </> "texo.png"
>   writeFile tex (document expr)
>   ink <- foreground
>   _ <- readProcess "latex" [ "-interaction=batchmode"
>                            , "-output-directory=" ++ tmp, tex ] ""
>   _ <- readProcess "dvipng" [ "-q", "-D", "300", "-T", "tight"
>                             , "-bg", "Transparent"
>                             , "-fg", fromMaybe "Black" ink
>                             , "-o", png, dvi ] ""
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

That is all of `texo`: one flag, two character tables, a four-line
LaTeX document, base64 from first principles, and an escape-code
envelope. Around a hundred lines of Haskell, and the program you just
read is the program you run. The obvious next steps are more symbols in
the table and `\frac`-style constructions in the Unicode translation;
both are additions to this essay, not to some other file.
