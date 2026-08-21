MD = $(wildcard book/*.md)

.PHONY: book ml2java ml2ts pdf clean

book:
	@test -n "$(MD)" || { echo "no book/*.md files yet"; exit 1; }
	pandoc -s --toc --metadata title="ML2X" -o book/book.html $(MD)

ml2java:
	cd ml2java && dune build

ml2ts:
	cd ml2ts && dune build

pdf:
	@test -n "$(MD)" || { echo "no book/*.md files yet"; exit 1; }
	pandoc --pdf-engine=typst -o book/book.pdf $(MD)

clean:
	rm -f book/book.html book/book.pdf
