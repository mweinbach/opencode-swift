#!/usr/bin/env bun
// Generates the compact Base64 + LEB128 minimal suffix-merged trie (DAWG) table for
// `RGI_Emoji_ZWJ_Sequence` in `Sources/OpenCodeCore/Codemode/CodemodeRegExpUnicodeData.swift`
// from official Unicode Emoji data (`emoji-zwj-sequences.txt`, downloaded strictly from unicode.org).
//
// Usage:
//   bun Tools/generate-regexp-zwj-table.ts                         # fetch 17.0.0 and print stats + literal
//   bun Tools/generate-regexp-zwj-table.ts --write                 # update CodemodeRegExpUnicodeData.swift in place
//   bun Tools/generate-regexp-zwj-table.ts --verify-bun            # also verify every sequence against Bun's RegExp
//   bun Tools/generate-regexp-zwj-table.ts --version=17.0.0        # override Unicode version (default: 17.0.0)
//   bun Tools/generate-regexp-zwj-table.ts --input=path/to/file    # read local emoji-zwj-sequences.txt offline
//
// Binary format (decoded by `RegExpUnicodeData.decodeStringDAWG` in pure Swift):
//   paletteCount: varint
//   palette[0..<paletteCount]: delta-encoded varints (cp - prevCp, initial prevCp = 0)
//   nodeCount: varint (post-order; root is nodeCount - 1)
//   For nodeIdx in 0..<nodeCount:
//     header: varint = (edgeCount << 1) | (isTerminal ? 1 : 0)
//     For each edge (sorted by paletteIdx ascending):
//       paletteIdx: varint
//       targetDelta: varint = nodeIdx - targetNodeIdx (always >= 1)

import fs from "fs"
import path from "path"

const ROOT_DIR = path.resolve(import.meta.dir, "..")
const SWIFT_DATA_PATH = path.join(ROOT_DIR, "Sources/OpenCodeCore/Codemode/CodemodeRegExpUnicodeData.swift")
const DEFAULT_UNICODE_VERSION = "17.0.0"

interface TrieNode {
  terminal: boolean
  children: Map<number, TrieNode>
}

interface DAWGNode {
  terminal: boolean
  edges: Array<[paletteIdx: number, targetId: number]>
}

function encodeVarint(out: number[], value: number): void {
  if (!Number.isInteger(value) || value < 0) {
    throw new Error(`Invalid unsigned varint value: ${value}`)
  }
  let v = value >>> 0
  while (v >= 0x80) {
    out.push((v & 0x7f) | 0x80)
    v >>>= 7
  }
  out.push(v)
}

function readVarint(bytes: Uint8Array, state: { idx: number }): number {
  let result = 0
  let shift = 0
  while (state.idx < bytes.length) {
    const b = bytes[state.idx++]!
    result |= (b & 0x7f) << shift
    if ((b & 0x80) === 0) break
    shift += 7
  }
  return result >>> 0
}

function parseEmojiZWJSequences(text: string): { sequences: number[][]; headerVersion: string | null; headerDate: string | null } {
  const versionMatch = text.match(/^#\s*Version:\s*(.+)$/m)
  const dateMatch = text.match(/^#\s*Date:\s*(.+)$/m)
  const seen = new Set<string>()
  const sequences: number[][] = []

  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.split("#")[0]!.trim()
    if (!line) continue
    const fields = line.split(";").map((s) => s.trim())
    if (fields.length < 2) continue
    if (fields[1] !== "RGI_Emoji_ZWJ_Sequence") {
      throw new Error(`Unexpected type field in emoji-zwj-sequences.txt: ${JSON.stringify(fields[1])}`)
    }
    const cps = fields[0]!.split(/\s+/).map((hex) => {
      if (!/^[0-9A-Fa-f]{4,6}$/.test(hex)) {
        throw new Error(`Invalid hex code point: ${JSON.stringify(hex)}`)
      }
      const cp = parseInt(hex, 16)
      if (cp < 0 || cp > 0x10ffff) {
        throw new Error(`Code point out of range: 0x${hex}`)
      }
      return cp
    })
    if (cps.length < 2) {
      throw new Error(`Expected multi-codepoint ZWJ sequence, got length ${cps.length}: ${fields[0]}`)
    }
    const key = cps.join(",")
    if (!seen.has(key)) {
      seen.add(key)
      sequences.push(cps)
    }
  }

  sequences.sort((a, b) => {
    const n = Math.min(a.length, b.length)
    for (let i = 0; i < n; i++) {
      if (a[i]! !== b[i]!) return a[i]! - b[i]!
    }
    return a.length - b.length
  })

  return {
    sequences,
    headerVersion: versionMatch ? versionMatch[1]!.trim() : null,
    headerDate: dateMatch ? dateMatch[1]!.trim() : null,
  }
}

function encodeStringDAWG(sequences: readonly number[][]): {
  base64: string
  rawBytes: number
  paletteCount: number
  nodeCount: number
  edgeCount: number
} {
  const palette = [...new Set(sequences.flat())].sort((a, b) => a - b)
  const cpToIdx = new Map<number, number>(palette.map((cp, idx) => [cp, idx]))

  // Build prefix trie of palette-indexed sequences
  const root: TrieNode = { terminal: false, children: new Map() }
  for (const seq of sequences) {
    let cur = root
    for (const cp of seq) {
      const idx = cpToIdx.get(cp)!
      let next = cur.children.get(idx)
      if (!next) {
        next = { terminal: false, children: new Map() }
        cur.children.set(idx, next)
      }
      cur = next
    }
    cur.terminal = true
  }

  // Suffix-merge identical subtrees into a minimal DAWG (post-order node numbering)
  const intern = new Map<string, number>()
  const nodes: DAWGNode[] = []
  function minimize(node: TrieNode): number {
    const entries = [...node.children.entries()].sort((a, b) => a[0] - b[0])
    const edges: Array<[number, number]> = entries.map(([palIdx, child]) => [palIdx, minimize(child)])
    const key = (node.terminal ? "T:" : "F:") + edges.map(([k, id]) => `${k}>${id}`).join(",")
    let id = intern.get(key)
    if (id === undefined) {
      id = nodes.length
      nodes.push({ terminal: node.terminal, edges })
      intern.set(key, id)
    }
    return id
  }
  const rootId = minimize(root)
  if (rootId !== nodes.length - 1) {
    throw new Error(`Expected post-order root id ${nodes.length - 1}, got ${rootId}`)
  }

  const out: number[] = []
  encodeVarint(out, palette.length)
  let prevCp = 0
  for (const cp of palette) {
    encodeVarint(out, cp - prevCp)
    prevCp = cp
  }

  encodeVarint(out, nodes.length)
  let edgeCount = 0
  for (let i = 0; i < nodes.length; i++) {
    const n = nodes[i]!
    encodeVarint(out, (n.edges.length << 1) | (n.terminal ? 1 : 0))
    for (const [palIdx, targetId] of n.edges) {
      if (targetId >= i) {
        throw new Error(`Post-order invariant violated: node ${i} -> ${targetId}`)
      }
      encodeVarint(out, palIdx)
      encodeVarint(out, i - targetId)
      edgeCount++
    }
  }

  const base64 = Buffer.from(out).toString("base64")
  return {
    base64,
    rawBytes: out.length,
    paletteCount: palette.length,
    nodeCount: nodes.length,
    edgeCount,
  }
}

// Exact mirror of `RegExpUnicodeData.decodeStringDAWG` in Swift, used for round-trip self-verification.
function decodeStringDAWG(base64: string): number[][] {
  if (base64.length === 0) return []
  const bytes = new Uint8Array(Buffer.from(base64, "base64"))
  const st = { idx: 0 }

  const paletteCount = readVarint(bytes, st)
  const palette: number[] = []
  let prevCp = 0
  for (let i = 0; i < paletteCount; i++) {
    prevCp += readVarint(bytes, st)
    palette.push(prevCp)
  }

  const nodeCount = readVarint(bytes, st)
  if (nodeCount === 0) return []

  const nodes: Array<{ terminal: boolean; edges: Array<[number, number]> }> = []
  for (let i = 0; i < nodeCount; i++) {
    const header = readVarint(bytes, st)
    const terminal = (header & 1) !== 0
    const edgeCount = header >>> 1
    const edges: Array<[number, number]> = []
    for (let e = 0; e < edgeCount; e++) {
      const palIdx = readVarint(bytes, st)
      const delta = readVarint(bytes, st)
      edges.push([palette[palIdx]!, i - delta])
    }
    nodes.push({ terminal, edges })
  }

  if (st.idx !== bytes.length) {
    throw new Error(`Trailing bytes after DAWG decode: consumed ${st.idx}/${bytes.length}`)
  }

  const out: number[][] = []
  const prefix: number[] = []
  function dfs(nodeId: number): void {
    const node = nodes[nodeId]!
    if (node.terminal) out.push([...prefix])
    for (const [cp, target] of node.edges) {
      prefix.push(cp)
      dfs(target)
      prefix.pop()
    }
  }
  dfs(nodeCount - 1)
  return out
}

function formatSwiftMultilineString(base64: string, indent = "        ", lineWidth = 100): string {
  const lines: string[] = []
  for (let i = 0; i < base64.length; i += lineWidth) {
    const chunk = base64.slice(i, i + lineWidth)
    const suffix = i + lineWidth < base64.length ? "\\" : ""
    lines.push(`${indent}${chunk}${suffix}`)
  }
  return `${indent}"""\n${lines.join("\n")}\n${indent}"""`
}

async function main(): Promise<void> {
  const args = process.argv.slice(2)
  const writeMode = args.includes("--write")
  const verifyBun = args.includes("--verify-bun")
  const versionArg = args.find((a) => a.startsWith("--version="))?.slice("--version=".length) ?? DEFAULT_UNICODE_VERSION
  const inputArg = args.find((a) => a.startsWith("--input="))?.slice("--input=".length)

  if (!/^\d+\.\d+\.\d+$/.test(versionArg)) {
    throw new Error(`Invalid --version value (expected X.Y.Z): ${versionArg}`)
  }

  const sourceUrl = `https://www.unicode.org/Public/${versionArg}/emoji/emoji-zwj-sequences.txt`
  let text: string
  let sourceLabel: string

  if (inputArg) {
    text = fs.readFileSync(inputArg, "utf8")
    sourceLabel = inputArg
  } else {
    const parsedUrl = new URL(sourceUrl)
    if (parsedUrl.protocol !== "https:" || parsedUrl.hostname !== "www.unicode.org") {
      throw new Error(`Refusing non-unicode.org download URL: ${sourceUrl}`)
    }
    const resp = await fetch(sourceUrl)
    if (!resp.ok) {
      throw new Error(`Failed to fetch ${sourceUrl}: HTTP ${resp.status} ${resp.statusText}`)
    }
    text = await resp.text()
    sourceLabel = sourceUrl
  }

  const { sequences, headerVersion, headerDate } = parseEmojiZWJSequences(text)
  if (sequences.length === 0) {
    throw new Error(`Parsed 0 RGI_Emoji_ZWJ_Sequence entries from ${sourceLabel}`)
  }

  const encoded = encodeStringDAWG(sequences)
  const decoded = decodeStringDAWG(encoded.base64)

  // Strict round-trip verification
  if (decoded.length !== sequences.length) {
    throw new Error(`Round-trip count mismatch: expected ${sequences.length}, decoded ${decoded.length}`)
  }
  for (let i = 0; i < sequences.length; i++) {
    const a = sequences[i]!
    const b = decoded[i]!
    if (a.length !== b.length || a.some((cp, j) => cp !== b[j])) {
      throw new Error(
        `Round-trip mismatch at index ${i}: expected [${a.map((c) => c.toString(16)).join(" ")}], got [${b.map((c) => c.toString(16)).join(" ")}]`,
      )
    }
  }

  if (verifyBun) {
    const reZwj = /^\p{RGI_Emoji_ZWJ_Sequence}$/v
    const reRgi = /^\p{RGI_Emoji}$/v
    let mismatches = 0
    for (const cps of decoded) {
      const s = String.fromCodePoint(...cps)
      if (!reZwj.test(s) || !reRgi.test(s)) {
        mismatches++
        if (mismatches <= 10) {
          console.error(`Bun RegExp mismatch for: ${cps.map((c) => c.toString(16).toUpperCase()).join(" ")}`)
        }
      }
    }
    if (mismatches > 0) {
      throw new Error(
        `Bun (v${Bun.version}, Unicode ${process.versions.unicode}, ICU ${process.versions.icu}) disagreed on ${mismatches} sequences`,
      )
    }
    console.error(
      `Verified ${decoded.length}/${decoded.length} sequences against Bun ${Bun.version} (Unicode ${process.versions.unicode}, ICU ${process.versions.icu}): 0 mismatches.`,
    )
  }

  const literal = formatSwiftMultilineString(encoded.base64)
  const commentLine = `    // Generated by Tools/generate-regexp-zwj-table.ts from ${sourceUrl}\n    // Unicode Emoji ${headerVersion ?? versionArg}${headerDate ? ` (${headerDate})` : ""}: ${sequences.length} sequences, ${encoded.paletteCount} unique CPs, ${encoded.nodeCount} DAWG nodes, ${encoded.edgeCount} edges, ${encoded.rawBytes} bytes (${encoded.base64.length} Base64 chars).`
  const block = `${commentLine}\n    private static let rgiEmojiZWJData: String =\n${literal}`

  console.error(
    `Source: ${sourceLabel} (Version ${headerVersion ?? versionArg})\n` +
      `Sequences: ${sequences.length}, Unique CPs: ${encoded.paletteCount}, DAWG: ${encoded.nodeCount} nodes / ${encoded.edgeCount} edges\n` +
      `Encoded size: ${encoded.rawBytes} raw bytes (${encoded.base64.length} Base64 chars)`,
  )

  if (writeMode) {
    const src = fs.readFileSync(SWIFT_DATA_PATH, "utf8")
    const re =
      /    \/\/ Generated by Tools\/generate-regexp-zwj-table\.ts[\s\S]*?    private static let rgiEmojiZWJData: String =\n        """[\s\S]*?        """/
    if (!re.test(src)) {
      throw new Error(
        `Could not locate generated rgiEmojiZWJData block in ${SWIFT_DATA_PATH}. Add placeholder markers or update manually first.`,
      )
    }
    const updated = src.replace(re, block)
    fs.writeFileSync(SWIFT_DATA_PATH, updated, "utf8")
    console.error(`Updated ${path.relative(ROOT_DIR, SWIFT_DATA_PATH)}.`)
  } else {
    process.stdout.write(block + "\n")
  }
}

await main()
