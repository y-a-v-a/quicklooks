// A line comment; the // in the URL below is not one.
/* Block comment spanning lines:
   function, return and const stay comment. */
import { readFile } from "node:fs/promises";

const BASE_URL = "https://example.com/api#v2";
const retries = 3;

export async function load(path, { encoding = 'utf8' } = {}) {
  const text = await readFile(path, encoding);
  return text.split("\n").filter((line) => line !== "");
}

class Cache extends Map {
  get(key) {
    return super.has(key) ? super.get(key) : undefined;
  }
}

const greeting = `Hello ${user.name}, you have ${count} new messages`;
console.log(typeof greeting === "string", retries * 2.5, null ?? true);
