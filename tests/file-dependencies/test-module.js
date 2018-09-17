#!/usr/bin/env node

const assert = require('assert')
const FN = require('./local_modules/ret-42')

assert.strictEqual(FN(), 42)
