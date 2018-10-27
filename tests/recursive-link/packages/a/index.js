#!/usr/bin/env node
const b = require("b");
const c = require("c");

if (b !== "b" && c !== "c") {
    process.exit(1);
}

process.exit(0);
