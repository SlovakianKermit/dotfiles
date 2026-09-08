// archive/tool/searxng.ts
import { tool } from "@opencode-ai/plugin";
import { z } from "zod";

// archive/tool/format.ts
function formatResults(data, maxResults = 10) {
  const sections = [];
  let answers = [];
  if (typeof data.answers === "string" && data.answers.length > 0) {
    answers = [data.answers];
  } else if (Array.isArray(data.answers) && data.answers.length > 0) {
    answers = data.answers.filter((a) => typeof a === "string" && a.length > 0);
  }
  if (answers.length > 0) {
    sections.push(`## Answers
` + answers.map((a) => `- ${a}`).join(`
`));
  }
  const fullCount = Array.isArray(data.results) ? data.results.length : 0;
  let results = [];
  if (Array.isArray(data.results)) {
    results = data.results.slice(0, maxResults);
  }
  if (results.length > 0) {
    const lines = results.map((r, i) => {
      const parts = [`${i + 1}.`];
      const block = [];
      if (typeof r.title === "string" && r.title.length > 0) {
        parts.push(`**${r.title}**`);
      }
      if (typeof r.url === "string" && r.url.length > 0) {
        parts.push(`— ${r.url}`);
      }
      block.push(parts.join(" "));
      if (typeof r.content === "string" && r.content.length > 0) {
        block.push(`   ${r.content}`);
      }
      return block.join(`
`);
    });
    sections.push(lines.join(`
`));
  }
  if (fullCount > maxResults) {
    sections.push(`Note: results capped at ${maxResults}. Use pageno=N for more.`);
  }
  let suggestions = [];
  if (Array.isArray(data.suggestions)) {
    suggestions = data.suggestions.filter((s) => typeof s === "string" && s.length > 0).slice(0, 5);
  }
  if (suggestions.length > 0) {
    sections.push(`### Suggestions
` + suggestions.map((s) => `- ${s}`).join(`
`));
  }
  let unresponsive = [];
  if (Array.isArray(data.unresponsive_engines)) {
    unresponsive = data.unresponsive_engines.map((e) => {
      if (typeof e === "string")
        return e;
      if (e && typeof e === "object") {
        return typeof e.engine === "string" ? e.engine : typeof e.name === "string" ? e.name : JSON.stringify(e);
      }
      return String(e);
    });
  }
  if (unresponsive.length > 0) {
    sections.push(`### Unresponsive engines
` + unresponsive.map((e) => `- ${e}`).join(`
`));
  }
  return sections.join(`

`);
}

// archive/tool/execute.ts
var FETCH_TIMEOUT_MS = Number(process.env.SEARXNG_FETCH_TIMEOUT_MS) || 1e4;
function resolveBaseUrl() {
  const value = (process.env.SEARXNG_URL ?? "").trim();
  if (value === "") {
    return "http://localhost:8888";
  }
  try {
    new URL(value);
  } catch {
    throw new Error(`Invalid SEARXNG_URL: '${value}'. Must be a valid URL (e.g., http://localhost:8888).`);
  }
  return value;
}
async function execute(args) {
  let baseUrl;
  try {
    baseUrl = resolveBaseUrl();
  } catch (err) {
    return err.message;
  }
  let pageno = args.pageno ?? 1;
  if (!Number.isFinite(pageno) || pageno < 1) {
    pageno = 1;
  }
  let maxResults = args.maxResults ?? 10;
  if (!Number.isInteger(maxResults) || maxResults < 1) {
    maxResults = 10;
  }
  try {
    const params = new URLSearchParams;
    params.set("format", "json");
    params.set("q", args.query);
    if (args.categories && args.categories !== "general") {
      params.set("categories", args.categories);
    }
    if (args.language && args.language !== "en") {
      params.set("language", args.language);
    }
    if (args.time_range) {
      params.set("time_range", args.time_range);
    }
    if (pageno !== 1) {
      params.set("pageno", String(pageno));
    }
    if (args.safesearch !== undefined && args.safesearch !== null) {
      params.set("safesearch", String(args.safesearch));
    }
    const url = `${baseUrl.replace(/\/$/, "")}/search?${params.toString()}`;
    const controller = new AbortController;
    const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
    try {
      const response = await fetch(url, {
        method: "GET",
        headers: {
          "User-Agent": "opencode-searxng/1.0 (SearXNG custom tool)"
        },
        signal: controller.signal
      });
      if (!response.ok) {
        let bodySnippet = "";
        try {
          bodySnippet = await response.text();
        } catch {}
        if (response.status === 403) {
          return `SearXNG returned 403 Forbidden. Hint: JSON format may not be enabled; ensure 'json' is in search.formats in settings.yml.`;
        }
        if (response.status === 429) {
          return `SearXNG returned 429 Too Many Requests. Hint: rate limiter may be on; ensure server.limiter is false, or check SEARXNG_URL.`;
        }
        const snippet = bodySnippet.length > 200 ? bodySnippet.slice(0, 200) + "…" : bodySnippet;
        return `SearXNG returned HTTP ${response.status}. Response: ${snippet}`;
      }
      let bodyText;
      try {
        bodyText = await response.text();
      } catch {
        return `Failed to read response body from SearXNG at ${baseUrl}. Check the SEARXNG_URL environment variable.`;
      }
      let data;
      try {
        data = JSON.parse(bodyText);
      } catch {
        const snippet = bodyText.length > 200 ? bodyText.slice(0, 200) + "…" : bodyText;
        return `SearXNG response is not valid JSON (HTTP ${response.status}). Response snippet: ${snippet}`;
      }
      return formatResults(data, maxResults);
    } finally {
      clearTimeout(timer);
    }
  } catch (err) {
    if (err?.name === "AbortError") {
      const timeoutSec = FETCH_TIMEOUT_MS / 1000;
      return `Search timed out after ${timeoutSec}s. The SearXNG instance at ${baseUrl} may be unresponsive. Check the SEARXNG_URL environment variable.`;
    }
    return `Cannot reach SearXNG at ${baseUrl}. Is the instance running? Check the SEARXNG_URL environment variable.`;
  }
}

// archive/tool/searxng.ts
const searxngTool = tool({
  name: "searxng",
  description: "Search the web via a local self-hosted SearXNG instance. Returns privacy-preserving aggregated results with no external API keys. Configure the instance URL via the SEARXNG_URL environment variable (default http://localhost:8888).",
  args: {
    query: z.string().describe("The search query. Supports SearXNG/per-engine syntax (e.g. site:github.com foo)."),
    categories: z.string().default("general").optional().describe("Comma-separated SearXNG search categories (e.g. general, images, news)."),
    language: z.string().default("en").optional().describe("Language code for search results (e.g. en, fr, de)."),
    time_range: z.enum(["day", "month", "year"]).optional().describe("Filter results by time range."),
    pageno: z.number().default(1).optional().describe("1-indexed page number for pagination."),
    safesearch: z.enum(["0", "1", "2"]).optional().describe("Safe search level: 0 = off, 1 = moderate, 2 = strict."),
    maxResults: z.number().default(10).optional().describe("Client-side cap on the number of results returned.")
  },
  execute: (args) => execute(args)
});
var searxng_default = searxngTool;
export {
  formatResults,
  execute,
  searxng_default as default,
  FETCH_TIMEOUT_MS
};
