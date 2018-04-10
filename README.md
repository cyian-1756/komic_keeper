# Komic keeper

Komic keeper is a comic manager written in D using vibe.d

## Building

Simply run `dub build`

## Set up

Create a config file named config.ini and enter the following into it

```
[config]
comic_path = $The full path to your comics
```

Then run setup.sh to make the database and covers folder

## Usage

To index comics run the program with `--index-comics`

To get the covers of your comics run the program with `--get-covers`


## Requirements

You have to have the progrma `unar` installed and in your path

You have to have the `imagemagick` package installed

You must have JavaScript enabled to use the search feature