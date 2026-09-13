import type { Address } from "viem";
import { infer } from "./agent.js";

// CLI: npx tsx orchestrator/src/index.ts "summarize this" 0xBorrower
const [prompt, borrower] = process.argv.slice(2);
if (prompt && borrower) {
  infer(prompt, borrower as Address).then((r) => console.log(r)).catch((e) => { console.error(e.message); process.exit(1); });
} else if (process.argv.length > 2) {
  console.error("usage: tsx orchestrator/src/index.ts <prompt> <borrowerAddress>");
  process.exit(1);
}
