// read-card: visiting card photo -> JSON (Gemini). Same key, model fallback and auth as read-bill.
// Salesman app "📷 Visiting card scan". Photo is NOT stored here; the app uploads it to the private
// 'visiting-cards' bucket itself after the salesman saves the lead.
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const J = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
const admin = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

let KEY: string | null = null;
async function getKey() {
  if (KEY) return KEY;
  KEY = Deno.env.get("GEMINI_API_KEY") || null;
  if (!KEY) {
    const { data } = await admin().from("app_secrets").select("value").eq("name", "gemini").maybeSingle();
    KEY = data?.value || null;
  }
  return KEY;
}
function role(req: Request) {
  try {
    const t = (req.headers.get("authorization") || "").split(" ")[1] || "";
    const p = JSON.parse(atob(t.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
    return p.role || "";
  } catch { return ""; }
}

const MODELS: [string, number][] = [
  ["gemini-flash-lite-latest", 30000], ["gemini-3.1-flash-lite", 30000], ["gemini-3.8-flash", 30000],
  ["gemini-3.5-flash", 25000], ["gemini-flash-latest", 25000],
];
const BIZ = ["Hardware dealer", "Distributor", "Interior designer", "Architect", "Furniture maker", "Builder", "Retail store", "Other"];

const PROMPT = `You read Indian business visiting cards (English, Gujarati, Hindi; glossy, angled, sometimes both sides in one photo).
Return ONLY JSON:
{"firm_name": business / shop name as printed (not the person),
 "person_name": the person's name, or null,
 "designation": e.g. Proprietor / Partner / Manager, or null,
 "mobiles": array of mobile numbers exactly as printed, Indian mobiles first (10 digits, may have +91 / spaces),
 "landline": landline with STD code, or null,
 "email": email or null,
 "website": website or null,
 "address": full street address line(s) as printed, WITHOUT city/state/pincode,
 "area": locality / road / area name (e.g. "Kalawad Road", "Aji GIDC"), or null,
 "city": city or town (e.g. Rajkot, Morbi, Ahmedabad). If only a pincode is printed, the city it belongs to,
 "state": state, or null,
 "pincode": 6-digit PIN or null,
 "gstin": 15-character GSTIN if printed, else null,
 "business_type": one of ${JSON.stringify(BIZ)} judged from the card's words (hardware, plywood, interior, architect, furniture, builders...),
 "products": short list of products / services printed on the card (max 120 chars) or null,
 "confidence": "high" | "medium" | "low"}
Rules: copy text exactly; never invent a number, email or address; use null for anything not printed or unreadable.`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const { image, mime, ping } = await req.json();
    if (!ping && role(req) !== "authenticated") return J({ ok: false, error: "LOGIN_REQUIRED" }, 401);
    if (!ping && !image) return J({ ok: false, error: "NO_IMAGE" }, 400);
    if (!ping && image.length > 8_000_000) return J({ ok: false, error: "Photo bahut badi hai" }, 413);
    const key = await getKey();
    if (!key) return J({ ok: false, error: "NO_KEY" }, 500);
    const parts: unknown[] = ping
      ? [{ text: 'Return JSON {"ok":true}' }]
      : [{ text: PROMPT }, { inline_data: { mime_type: mime || "image/jpeg", data: image } }];
    const body = JSON.stringify({ contents: [{ parts }], generationConfig: { responseMimeType: "application/json", temperature: 0 } });
    const tried: string[] = [];
    for (const [m, ms] of MODELS) {
      let r: Response;
      try {
        r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${m}:generateContent`, {
          method: "POST", headers: { "Content-Type": "application/json", "x-goog-api-key": key }, body, signal: AbortSignal.timeout(ms),
        });
      } catch { tried.push(`${m} timeout`); continue; }
      const t = await r.text();
      if (!r.ok) { tried.push(`${m} ${r.status}`); if ([400, 404, 429, 500, 503].includes(r.status)) continue; return J({ ok: false, error: tried.join("; ") }, 502); }
      const d = JSON.parse(t);
      const txt = d?.candidates?.[0]?.content?.parts?.map((p: { text?: string }) => p.text || "").join("") || "";
      let out: any;
      try { out = JSON.parse(txt.replace(/```json|```/g, "").trim()); } catch { tried.push(`${m} badjson`); continue; }
      if (Array.isArray(out)) out = out[0];
      return J({ ok: true, model: m, tried, data: out });
    }
    return J({ ok: false, error: "Google AI abhi busy hai, 1 minute baad dobara photo lagao", tried }, 503);
  } catch (e) {
    return J({ ok: false, error: String((e as Error)?.message || e) }, 500);
  }
});
