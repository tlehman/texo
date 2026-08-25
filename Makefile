
tangle:
	ghc -O2 texo.lhs -o texo

weave:
	pandoc -f markdown+lhs texo.lhs --pdf-engine=xelatex -o texo.pdf

clean:
	rm texo.o texo.hi texo texo.pdf
