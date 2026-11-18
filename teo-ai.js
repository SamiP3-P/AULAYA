import { CreateMLCEngine, deleteModelAllInfoInCache } from "@mlc-ai/web-llm";

const MODEL_ID = "Qwen2.5-0.5B-Instruct-q4f32_1-MLC";
const PREVIOUS_MODEL_ID = "SmolLM2-360M-Instruct-q4f32_1-MLC";
let engine = null;
let loading = null;

window.teoOfflineAI = {
  get ready() { return Boolean(engine); },
  async init(onProgress = () => {}) {
    if (engine) return engine;
    if (loading) return loading;
    if (!navigator.gpu) throw new Error("WebGPU no está disponible en este dispositivo.");
    try { await navigator.storage?.persist?.(); } catch (_) { /* El navegador decide si conserva el almacenamiento. */ }
    loading = CreateMLCEngine(MODEL_ID, {
      initProgressCallback: (progress) => onProgress({
        progress: Math.round((progress.progress || 0) * 100),
        text: progress.text || "Descargando y preparando el modelo…",
      }),
    }).then((instance) => {
      engine = instance;
      localStorage.setItem("teo-model-cache-v2", "ready");
      deleteModelAllInfoInCache(PREVIOUS_MODEL_ID).catch(() => {});
      return engine;
    }).finally(() => { loading = null; });
    return loading;
  },
  async reply(messages) {
    if (!engine) throw new Error("El modelo todavía no está preparado.");
    const result = await engine.chat.completions.create({
      messages,
      temperature: 0.65,
      max_tokens: 180,
      stream: false,
    });
    return result.choices?.[0]?.message?.content?.trim() || "¿Me lo puedes preguntar de otra forma?";
  },
};
