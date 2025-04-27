+++
title = "The Markdown to PDF pipeline I wish someone told me about"
description = ""
date = 2025-04-26

[taxonomies]
tags = [ "markdown", "pandoc", "typst" ]
+++

I recently found myself in a situation where I needed to write up a document
intended to be updated once or twice per year and otherwise kept printed out as
a hard copy in a safe location. The only requirement I have is that I want to be
able to write in Markdown (I write a lot of Markdown and find it to be minimal
enough fuss that I can focus on getting content on to a page) and be able to
render to something that can easily be printed out (like PDF!).

Although there are resources online on doing this, I had to read through and
cobble together information from various places, so hopefully this ends up being
a nicer quick start for someone else!

<!-- more -->

In the end I settled on the moral equivalent (not to scale) of<br>
`cat *.md | pandoc | typst >out.pdf`, modulo some minor configuration which is
easy to set and forget once it fits your liking.

[Pandoc] is basically a Swiss Army knife for converting between different
markup formats, and [Typst] is a modern typesetting system (in the same vein as
LaTeX but way easier to use and get running). Thus, Typst knows how to take some
layout markup and some content and spit out a PDF, while Pandoc knows how to
convert Markdown to whatever inputs Typst is used to parsing.

The final missing piece is giving Pandoc a little bit of metadata and a template
file which will set up the Typst preamble and default styling. Pandoc has _a
lot_ of flags and functionality it supports and I got lost in the docs for a
while trying to make sense of how to inject my own styles as overrides into
Pandoc's default Typst template, so I gave up and adapted a template I found
online and made it my own (which in hindsight ended up being way simpler).


Save the following (and tweak it to your liking) under `metadata.yaml`:
```yaml
title: Hello world!
subtitle: A simple Markdown to PDF pipeline
```

Then save the following (and tweak it to your liking) under `my.template`:
```perl
// Loosely based on
// https://web.archive.org/web/20250427030050/https://imaginarytext.ca/posts/2024/pandoc-typst-tutorial/
#let conf(
  title: none,
  subtitle: none,
  date: datetime.today().display(),
  lang: "en",
  paper: "a4",
  body,
) = {
  set page(
    paper: paper,

    footer: context [
      #set text(style: "italic")
      Last updated: #date #h(1fr) #counter(page).display("1 of 1", both: true)
    ],
  )

  // BASIC BODY PARAGRAPH FORMATTING
  set par(
    first-line-indent: 0em,
    justify: true,
  )
  set text(
    lang: lang,
    alternates: false,
  )

  // Block quotations
  set quote(block: true)
  show quote: set pad(x: 2em) // L&R margins
  show quote: set text(style: "italic")

  // HEADINGS
  show heading: it => {
    if it.depth == 1 {
      pagebreak(weak: true)
    }
    set text(hyphenate: true)
    it
  }

  // Title page and TOC
  align(horizon + center, [
    #text(size: 2.5em)[#title]

    #text(size: 1em, style: "italic")[#subtitle]
    #v(25%)
  ])
  pagebreak()
  set heading(numbering: "1.")
  outline(
    title: auto,
    indent: auto,
  );
  pagebreak()

  // THIS IS THE ACTUAL BODY:
  body
}

// BOILERPLATE PANDOC TEMPLATE:

#show: body => conf(
$if(title)$
  title: [$title$],
$endif$
$if(subtitle)$
  subtitle: [$subtitle$],
$endif$
$if(date)$
  date: [$date$],
$endif$
$if(lang)$
  lang: "$lang$",
$endif$
$if(papersize)$
  paper: "$papersize$",
$endif$
  body,
)

$body$

$for(include-after)$

$include-after$
$endfor$
```

Lastly invoke the whole thing via:
```sh
pandoc \
  --pdf-engine=typst \
  -o out.pdf \
  --template=my.template \
  --metadata-file=metadata.yaml \
  *.md
```

[Pandoc]: https://pandoc.org/
[Typst]: https://typst.app/docs/
