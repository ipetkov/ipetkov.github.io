# About

Hello! Looks like you've found the repo for my blog.

If you've landed here by accident, I recommend looking at the actual web page, I
promise its much better :)

But, if you're here to find some inspiration, feel free to look under the hood!

## Updating Zola

Zola versions usually fix a number of bugs but sometimes there may be
regressions. A good way to check for them is to build the site before and after
the Zola bump and check the diff of the output.

For now, the process is manual, maybe it can be automated if it happens
frequently enough...

1. Edit config.toml and disable `minify_html`
1. `zola build --output-dir public-old`
1. `nix flake update`
1. `zola build`
1. `delta public-old public`
1. If there are differences, investigate/fix them...
