import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const MODEL_CHAIN = (Deno.env.get("VYNTRA_GEMINI_MODELS") ??
  "gemini-3.8-flash,gemini-3.5-flash-lite,gemini-2.5-flash-lite,gemini-2.5-flash")
  .split(",").map((value) => value.trim()).filter(Boolean);

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const apiKey = Deno.env.get("GEMINI_API_KEY");
  if (!apiKey) return json({ error: "ai_not_configured", message: "Vyntra AI is not configured on the server." }, 503);

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const instruction = typeof payload.instruction === "string" ? payload.instruction.trim() : "";
  if (!instruction || instruction.length > 4000) {
    return json({ error: "invalid_instruction", message: "Provide an editing instruction of 1–4000 characters." }, 400);
  }

  const project = payload.project;
  const projectJson = project == null ? "{}" : JSON.stringify(project);
  if (projectJson.length > 100_000) return json({ error: "project_too_large" }, 413);

  const systemPrompt = [
    "You are Vyntra's video-editing assistant.",
    "Return only valid JSON with keys: summary (string), suggestions (array of objects), warnings (array of strings).",
    "Each suggestion must contain action (one of trim, reorder, crop, rotate, adjust_picture, adjust_audio, add_text, add_music, export_settings), target (string), and parameters (object).",
    "Never invent project clip IDs. Use IDs present in the supplied project. If a requested edit is not represented by the project schema, explain that in warnings instead of pretending it was applied.",
    "Do not return executable code, shell commands, FFmpeg arguments, URLs, or credentials. These are suggestions only and must be confirmed by the editor before changing a project.",
    "Respect existing project clip bounds and supported aspect ratios. Do not claim to have edited or rendered any file.",
  ].join("\n");

  const body = {
    system_instruction: { parts: [{ text: systemPrompt }] },
    contents: [{
      role: "user",
      parts: [{ text: JSON.stringify({ instruction, project: JSON.parse(projectJson) }) }],
    }],
    generationConfig: { responseMimeType: "application/json", temperature: 0.2, maxOutputTokens: 1800 },
  };

  const failures: string[] = [];
  for (const model of MODEL_CHAIN) {
    let response: Response;
    try {
      response = await fetch(
        `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent?key=${encodeURIComponent(apiKey)}`,
        { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body), signal: AbortSignal.timeout(25_000) },
      );
    } catch {
      failures.push(`${model}:network_error`);
      continue;
    }

    if (response.ok) {
      const result = await response.json();
      const text = result?.candidates?.[0]?.content?.parts?.map((part: { text?: string }) => part.text ?? "").join("") ?? "";
      try {
        const parsed = JSON.parse(text);
        if (typeof parsed.summary !== "string" || !Array.isArray(parsed.suggestions) || !Array.isArray(parsed.warnings)) {
          return json({ error: "invalid_model_response", message: "The AI response did not match the expected edit-plan format." }, 502);
        }
        return json({ model, plan: parsed, applied: false });
      } catch {
        return json({ error: "invalid_model_response", message: "The AI returned an unreadable edit plan." }, 502);
      }
    }

    const retryable = [404, 429, 500, 502, 503, 504].includes(response.status);
    failures.push(`${model}:http_${response.status}`);
    if (!retryable) {
      return json({ error: "ai_request_rejected", message: "The AI request was rejected. Check the request and server configuration." }, 400);
    }
  }

  console.error("Vyntra Gemini fallback exhausted", failures.join(","));
  return json({
    error: "ai_models_unavailable",
    message: "All configured Gemini models are currently unavailable or rate-limited. Please try again later.",
  }, 503);
});
