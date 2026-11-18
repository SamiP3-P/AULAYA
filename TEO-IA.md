# Teo sin conexión

Teo usa WebLLM y el modelo local `Qwen2.5-0.5B-Instruct-q4f32_1-MLC`. Qwen2.5 declara soporte multilingüe, incluido español. Las preguntas y respuestas se generan en el navegador; no se envían a una API ni se guardan en el perfil.

## Primera preparación

1. Sirve la carpeta desde `localhost` o un sitio HTTPS (WebGPU y el service worker no funcionan desde `file://`).
2. Abre la pestaña **Teo** con conexión y pulsa **Preparar modelo**. La descarga puede ocupar varios cientos de MB; espera a que Teo indique que está listo.
3. El modelo queda guardado en el almacenamiento del navegador. El botón de descarga desaparece y, al volver a abrir Teo, se carga desde esa copia. Luego puedes desconectar internet.

Cada dispositivo/navegador debe preparar el modelo una vez. Si borras los datos del sitio o cambias de navegador, tendrás que descargarlo otra vez. Se requiere un navegador compatible con WebGPU; Chrome o Edge actualizado son buenas opciones.

Teo está configurado para ayudar con preguntas y otros pedidos académicos: explicaciones, ejemplos, tareas, material de clase y ejercicios. Responde en español sencillo, apropiado para primaria. Al ser un modelo pequeño, puede equivocarse.

## Compilar el motor

```sh
npm install
npm run build:ai
```

El paquete compilado en `assets/teo-ai.bundle.js` se entrega con la app. Los pesos no están en el repositorio: se guardan en el navegador al preparar Teo.
