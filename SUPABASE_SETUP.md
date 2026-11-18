# Configurar la base de datos de Aula ya!

Aula ya usa Supabase Auth para las cuentas y PostgreSQL para los perfiles y el progreso. El mismo proyecto sirve para web y para una APK con conexión a internet. Los docentes pueden subir videos MP4 o WebM de hasta 50 MB a sus clases. Los estudiantes inscritos descargan el archivo dentro de la lección; queda guardado en el almacenamiento local del navegador o APK y se puede reproducir sin conexión en ese mismo dispositivo. El archivo no se sincroniza a otros dispositivos. Los cambios de progreso se guardan primero en el dispositivo y se ponen en una cola persistente; al volver internet, Aula ya los envía automáticamente.

## Proyecto conectado

El proyecto Supabase **AulaYa-Production** ya está creado en el plan Free. La tabla `public.profiles` y sus políticas RLS están creadas. La configuración local usa la URL y clave pública de ese proyecto. La clave pública puede estar en la app; la clave secreta de servidor nunca debe incluirse.

La opción **Authentication → Sign In / Providers → Confirm email** está activada. El registro espera la confirmación antes de iniciar sesión; también hay opciones para reenviar el correo, recuperar la contraseña y cambiarla desde el perfil. La confirmación prueba que la persona puede abrir el enlace enviado a esa dirección.

## Puesta en marcha

1. En el dashboard del proyecto, ejecuta la versión actualizada de `supabase-schema.sql`. Además de las tablas existentes, crea la tabla de videos compartidos, el bucket privado `class-videos` y las políticas que permiten acceso al docente dueño y a estudiantes inscritos.
2. En **Authentication → URL Configuration**, agrega el dominio final de la web y el origen de desarrollo a las URL permitidas.
3. Antes de enviar correos a estudiantes y docentes, configura un SMTP propio en Supabase: el servicio de correo predeterminado solo permite destinatarios que sean integrantes de la organización y tiene un límite bajo de envío.
4. Despliega la web o APK. Los cambios se guardan en el dispositivo y se envían a Supabase al haber sesión e internet; si falla la subida, quedan pendientes para reintentar.

`supabase-config.js` se carga desde la app. Completa sus valores antes de desplegar. La clave pública anon/publishable está diseñada para usarse en clientes; la protección de datos la aplican las políticas RLS incluidas en el SQL. Nunca escribas una clave `service_role` o `secret` en ese archivo.

## Datos y acceso

La tabla `profiles` guarda rol, institución, grado, materias y el estado de Aula ya en JSONB. Cada cuenta solo puede leer y modificar su propio perfil según las políticas RLS. La búsqueda de estudiantes usa funciones protegidas en la base de datos: el docente solo recibe resultados de estudiantes con municipio, corregimiento/vereda e institución coincidentes. La inscripción queda en `class_memberships` y el servidor vuelve a comprobar los datos al agregar a cada estudiante. La clave de contraseña la gestiona Supabase Auth; Aula ya no envía contraseñas a la tabla de perfiles.

El inicio de sesión y la sincronización requieren internet. Para publicar la APK y la web, usa el mismo proyecto de Supabase y agrega ambos dominios/orígenes permitidos. No incluyas jamás una clave `service_role` en la aplicación.

Los avisos de apoyo de bajo progreso se almacenan en `teacher_notifications`. Al salir de una lección con avance entre 0 % y 60 %, el estudiante registra un aviso para sus docentes inscritos; si no hay conexión, queda en cola local y se envía al reconectarse. Los avisos aparecen en la campana docente y se deduplican por estudiante, docente y lección.

## Videos de clase y uso sin conexión

Para activar las subidas, ejecuta `supabase-schema.sql` en el SQL Editor del proyecto. El bucket es privado: cada archivo queda bajo el identificador del docente y de la clase; las políticas solo dejan que ese docente lo gestione y que sus estudiantes inscritos lo lean. El docente selecciona el video al crear la actividad. El estudiante debe tocar **Descargar** mientras tenga internet. La app guarda el archivo en IndexedDB y muestra **Ver sin internet** en ese mismo dispositivo. Si borra los datos del navegador o desinstala la APK, el video descargado se elimina y debe bajarse otra vez.
