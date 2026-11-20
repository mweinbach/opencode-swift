import { describe, expect, test } from "bun:test"
import { extractBalancedSnippetTS } from "./scanner.ts"

// Regression coverage for the v2 statement-end snippet rule. Under v1 the snippet stopped at the
// first `}` that returned brace depth to zero, so every case below hashed only a prefix and upstream
// body edits went undetected by the drift gate.
const snip = (src: string, tsx = false) => extractBalancedSnippetTS(src, 0, tsx)

describe("extractBalancedSnippetTS (v2 statement-end rule)", () => {
  test("function with destructured parameter includes its body", () => {
    const src = `export function f({ a, b }: Opts) {\n  return a + b\n}\nexport const next = 1\n`
    expect(snip(src)).toBe(`export function f({ a, b }: Opts) {\n  return a + b\n}`)
  })

  test("arrow with destructured parameter includes its body", () => {
    const src = `export const C = ({ x }: Props) => {\n  return x\n}\n\nexport const D = 2\n`
    expect(snip(src)).toBe(`export const C = ({ x }: Props) => {\n  return x\n}`)
  })

  test("object return type does not end the declaration", () => {
    const src = `export function g(): { ok: boolean } {\n  return { ok: true }\n}\nconst z = 0\n`
    expect(snip(src)).toBe(`export function g(): { ok: boolean } {\n  return { ok: true }\n}`)
  })

  test("array of endpoint builders covers every element", () => {
    const src = [
      "export const Endpoints = [",
      '  A.get("x", "/x", { query: Q }),',
      '  A.post("y", "/y", { params: { id: S } }).annotate({ id: "y" }),',
      "] as const",
      "",
      "export const Other = 1",
    ].join("\n")
    expect(snip(src)).toBe(src.split("\n\n")[0])
  })

  test("pipe chains and `as const` after an object literal are included", () => {
    const src = `export const S = Schema.Struct({\n  a: Schema.String,\n}).pipe(Schema.brand("S"))\nexport const T = { a: 1 } as const\n`
    expect(snip(src)).toBe(`export const S = Schema.Struct({\n  a: Schema.String,\n}).pipe(Schema.brand("S"))`)
    const t = src.indexOf("export const T")
    expect(extractBalancedSnippetTS(src, t, false)).toBe(`export const T = { a: 1 } as const`)
  })

  test("multi-line union types continue across leading `|`", () => {
    const src = `export type U =\n  | { kind: "a" }\n  | { kind: "b" }\nexport type V = string\n`
    expect(snip(src)).toBe(`export type U =\n  | { kind: "a" }\n  | { kind: "b" }`)
  })

  test("URLs containing // are not treated as comments", () => {
    const src = `export const BASE = "https://api.example.com/v1"\nexport const PATH = "/messages"\n`
    expect(snip(src)).toBe(`export const BASE = "https://api.example.com/v1"`)
    const tpl = "export const uri = (id: string) => (id ? `skill://${id}/x` : `skill://${id}`)\n\nexport const isUri = 1\n"
    expect(snip(tpl)).toBe("export const uri = (id: string) => (id ? `skill://${id}/x` : `skill://${id}`)")
  })

  test("overload signatures without bodies end at the newline", () => {
    const src = `export function h(a: string): void\nexport function h(a: number): void\nexport function h(a: unknown) {}\n`
    expect(snip(src)).toBe(`export function h(a: string): void`)
  })

  test("trailing line comment does not swallow the next statement", () => {
    const src = `export const A = 1 // the answer\nexport const B = 2\n`
    expect(snip(src)).toBe(`export const A = 1 // the answer`)
  })

  test("class bodies end at their closing brace", () => {
    const src = `export class K extends Base<{ a: 1 }> {\n  m() { return 1 }\n}\nexport const after = 1\n`
    expect(snip(src)).toBe(`export class K extends Base<{ a: 1 }> {\n  m() { return 1 }\n}`)
  })

  test("TSX component with destructured props includes JSX body", () => {
    const src = `export function Row({ label }: { label: string }) {\n  return <box>{label}</box>\n}\nexport const x = 1\n`
    expect(snip(src, true)).toBe(`export function Row({ label }: { label: string }) {\n  return <box>{label}</box>\n}`)
  })
})
