#!/usr/bin/env node
'use strict';

var ArgumentParser = require('argparse').ArgumentParser;
var parser = new ArgumentParser({
  version: '0.0.1',
  addHelp:true,
  description: 'Argparse example'
});
parser.addArgument(
  [ '-f', '--foo' ],
  {
    help: 'foo bar'
  }
);
parser.addArgument(
  [ '-b', '--bar' ],
  {
    help: 'bar foo'
  }
);
parser.addArgument(
  '--baz',
  {
    help: 'baz bar'
  }
);
var args = parser.parseArgs();
console.dir(args);
