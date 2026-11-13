# Software Factory

Lleva issues de GitHub hasta un pull request revisado, con agentes de Claude Code:
un **Planner** escribe spec, plan y tareas; un **Reviewer** revisa el plan y luego el PR;
un **Developer** implementa. Un panel web muestra en qué etapa está cada issue, cuánto
tardó en cada una, qué modelo se usó y cuánto costó.

## Requisitos

- Elixir, PostgreSQL
- `gh` autenticado (`gh auth status`) con acceso a los repositorios
- `claude` (Claude Code) autenticado
- `codex` (Codex CLI) autenticado, solo si el Reviewer usa un modelo de Codex
- Las herramientas del stack de cada repositorio (bundler, mix, cargo, go, npm…)

## Arranque

```sh
mix setup
mix phx.server   # http://localhost:4000
```

1. En **Projects → Add project** elige el repositorio, el tipo de aplicación
   (Rails, Elixir, Rust, Go o Node) y el modelo y esfuerzo de cada rol.
   El Reviewer puede usar un modelo de Claude o de Codex (`codex exec` en modo solo
   lectura); el resto de roles, solo Claude. Codex informa tokens pero no costo, y el
   tope de gasto por ejecución no se le aplica.
   El panel separa el tiempo de la factory (en cola o con un agente trabajando) del
   tiempo esperando a una persona (respuestas, aprobaciones, merge, reintentos).
2. Si el repositorio necesita variables con secretos para el setup, los tests o el lint
   (API keys, un `DATABASE_URL` propio…), añádelas en la sección **Secrets** de la
   edición del proyecto (solo administradores). Ver [Secretos del proyecto](#secretos-del-proyecto).
3. Pon la etiqueta `factory:ready` (configurable) a un issue. La factory lo recoge en
   menos de un minuto.

### Secretos del proyecto

En **Projects → (proyecto) → Secrets** se añade cada secreto con un nombre de variable
de entorno (`DATABASE_URL`, `API_KEY`…), su valor (admite varias líneas, p. ej. una clave
PEM) y la casilla **Only for the checks**:

- Los checks (setup, tests y lint) reciben todos los secretos.
- El Developer recibe los que no son "solo para checks", y su prompt nombra unos y otros
  (sin valores). Planner, Reviewer, `gh` y `git` no reciben ninguno.
- El valor se guarda cifrado (AES-256-GCM con `FACTORY_SECRETS_KEY`) y no se vuelve a
  mostrar: se puede **reemplazar** (con el valor vacío solo cambia la casilla) o borrar.
- Mínimo 8 caracteres. Los nombres que la factory usa o pasa a todos los procesos
  (`PATH`, `HOME`, `LC_*`, `FACTORY_*`, `ANTHROPIC_*`, `CLAUDE_*`, los de
  `FACTORY_ENV_PASSTHROUGH`…) están reservados.
- En todo lo que la factory guarda o publica (comentarios, PR, historial, resultados de
  los checks y de los agentes) cada valor aparece como `[SECRET:NOMBRE]`.
- La lista marca los secretos guardados con otra clave y los que tienen un nombre que
  pasó a estar reservado (no se usan).

## Usuarios y permisos

Hay que iniciar sesión para ver cualquier página. La primera vez que abres la factory
(sin usuarios) te pide crear el primer administrador; después nadie puede registrarse
por su cuenta: los usuarios se crean en **Users**, con nombre, apellidos, correo,
contraseña (mínimo 12 caracteres) y un nivel de acceso:

| Nivel | Puede |
| --- | --- |
| Administrator | Todo: proyectos, usuarios y acciones sobre los issues |
| Operator | Aprobar planes, pedir cambios al plan o al PR, reintentar y detener issues. No cambia proyectos ni usuarios |
| Read only | Ver todo, sin cambiar nada |

- Cada persona cambia su contraseña en su cuenta (el círculo con sus iniciales).
- Cambiar el nivel, la contraseña o desactivar a alguien cierra todas sus sesiones.
- Siempre debe quedar un administrador activo.
- Las acciones hechas desde el panel quedan con el nombre de quien las hizo. Los
  comentarios en GitHub salen todos con la cuenta de `gh` de la máquina, así que al
  pedir cambios a un plan o a un PR se añade al comentario quién lo escribió.

## Flujo

```
planning ──preguntas──▶ awaiting_answers ──respuesta──▶ planning
   │
   ▼
plan_review ──cambios (máx. N rondas)──▶ planning
   │ aprobado
   ▼
[awaiting_plan_approval]  solo si el proyecto lo pide (por defecto: issues difíciles)
   │
   ▼
developing ──▶ checks (tests + lint) ──▶ push + PR
   ▼
pr_review ──cambios (máx. N rondas)──▶ developing
   │ aprobado
   ▼
ready_to_merge ──merge de una persona──▶ done
   │
   └──cambios pedidos por una persona──▶ developing
```

- El Planner clasifica el issue en `easy`, `medium` o `hard`; eso decide el modelo del
  Developer.
- Al agotar las rondas de revisión el issue pasa a `needs_human`. Cada ronda adicional
  la autoriza una persona.
- Con el PR abierto y el issue en `ready_to_merge`, o en `needs_human` por rondas de
  revisión agotadas, una persona puede pedir cambios al PR (comentando en GitHub o
  desde la página del issue). El issue vuelve a `developing` y hace otra ronda completa:
  Developer, checks, push y Reviewer del PR. Esas rondas no gastan rondas automáticas:
  en `ready_to_merge` el límite sube en 1, y en `needs_human` queda en la ronda actual + 1.
- El Developer recibe lo pedido como decisión de un maintainer, con archivo y línea si
  es un comentario de revisión, y el Reviewer comprueba que esté hecho. Cuando el PR se
  aprueba, esos cambios pasan a ser decisiones ya acordadas: las rondas siguientes del
  mismo PR las siguen recibiendo como parte del alcance.
- Solo cuenta lo escrito mientras el issue espera en esos dos estados. Lo que se escribe
  mientras la factory trabaja (`developing`, `pr_review`…) o mientras espera por otro
  motivo no se recoge: escribe cuando el issue esté en **Ready to merge**. Si se escribe
  algo justo cuando se abre una ronda, se atiende en la siguiente, cuando el issue
  vuelve a esperar.
- Al entrar en `developing` corre el setup del stack, registrado como una ejecución
  **Setup** en la página del issue (con su salida, filtrada, si falla). No arranca si el
  issue ya se detuvo.
- Si los checks fallan, el Developer lo reintenta (3 intentos; el último con el modelo
  del nivel superior). Si siguen fallando, `needs_human`, sin abrir PR.
- Si el proyecto tiene secretos, antes de cada push (del plan y del código) la factory
  revisa lo que enviaría: los mensajes y las líneas añadidas de los commits que no están
  en `origin/<rama del issue>` ni en `origin/<rama base>`. En un merge cuenta lo que el
  propio merge cambia (resolución de conflictos), no lo que trae de sus padres; un merge
  de tres o más ramas (octopus) no se puede revisar y hace fallar la etapa. Si aparece el
  valor de un secreto, no hay push ni PR: el issue queda en `needs_human` ("The changes
  contain the value of a project secret") con un comentario que nombra el secreto, y al
  aprobarlo el Developer recibe el encargo de quitarlo de los commits sin publicar.
  Necesita git ≥ 2.36 (`--remerge-diff`); con uno anterior la revisión falla y no hay push.
- Si los secretos del proyecto no se pueden descifrar (falta la clave, es otra, o el dato
  está alterado), la etapa no lanza nada y el issue pasa a `failed` nombrándolos; se
  reintenta con `/factory retry` o el botón Retry tras corregirlo.
- La factory nunca hace merge.

Spec, plan y tareas quedan en la rama del issue, en `.factory/issue-N/`, y forman parte
del PR.

## Estado en GitHub

La factory refleja el avance en el propio issue, para cualquier rama base:

| Momento | En el issue |
| --- | --- |
| Al recogerlo, y mientras se planifica y desarrolla | etiqueta `factory:in-progress` |
| Desde que se abre el PR | etiqueta `factory:in-review` |
| PR mergeado | se quitan las etiquetas y se cierra el issue con un comentario |
| PR cerrado sin merge, o issue detenido | se quitan las etiquetas; el issue queda abierto |

GitHub solo cierra issues por sí mismo (`Closes #N`) cuando el PR va a la rama por
defecto; por eso la factory lo hace explícitamente. Si en el proyecto desmarcas
"Close the issue when its pull request is merged", el issue queda abierto con la
etiqueta `factory:merged`.

## Página del issue

La página de cada issue muestra `spec.md`, `plan.md` y `tasks.md` en cuanto existen,
leídos de la rama del issue. Mientras el plan espera aprobación puedes aprobarlo ahí
mismo o escribir qué debe cambiar: ese texto se publica en el issue de GitHub como
comentario tuyo y el Planner revisa el plan.

Con el PR abierto esperando una persona (`ready_to_merge`, o `needs_human` por rondas
de revisión agotadas), la página muestra **Request changes to the pull request**:
escribe qué debe cambiar y el issue vuelve a `developing` en el momento. El comentario,
firmado con tu nombre, se publica en el PR en segundo plano (si GitHub falla se
reintenta, sin duplicarlo). Si el PR ya no está abierto, o el issue ya no espera
cambios, no se envía nada.

## Comandos en GitHub

En un comentario del issue o del PR, al inicio de una línea:

| Comando | Efecto |
| --- | --- |
| `/factory approve` | Aprueba el plan, o autoriza una ronda más, o reintenta |
| `/factory retry` | Reintenta una etapa fallida |
| `/factory stop` | Detiene el trabajo en el issue, también en Ready to merge |

Si un agente o un check ya está en marcha al detener el issue, termina, pero su
resultado se descarta: no se publica nada más, ni commit, push o PR.

Cualquier otro comentario mientras se esperan respuestas o la aprobación del plan vuelve
a planificación con ese comentario como contexto. Lo mismo se puede hacer con los
botones de la página del issue.

Con el issue en Ready to merge, o en `needs_human` por rondas de revisión agotadas, y
el PR abierto, cualquier otro comentario de un usuario permitido pide cambios al PR: en
el issue, en la conversación del PR, como texto de un review enviado o como comentario
sobre una línea (los reviews en borrador no cuentan). Varios comentarios de una misma
pasada van juntos en una ronda, y la factory avisa en el PR de que recibió los cambios
y de que el Developer trabaja en ellos. En Ready to merge, un `/factory approve` o
`/factory retry` suelto no hace nada.

## Seguridad

- Solo se actúa sobre comentarios de los usuarios listados en el proyecto. Los demás
  comentarios llegan a los agentes marcados como contexto no verificado.
- Los comentarios de la factory llevan un marcador oculto, porque publica con tu misma
  cuenta de `gh`.
- Planner y Reviewer no pueden ejecutar comandos arbitrarios; el Reviewer tampoco
  escribir. **El Developer sí ejecuta comandos en tu máquina**, sin contenedor: úsalo
  con repositorios e issues en los que confíes.
- Los clones viven en `~/.software-factory` (o `FACTORY_HOME`), separados de tus copias
  de trabajo.
- Los procesos que lanza la factory reciben un entorno mínimo (ver
  [Despliegue](#despliegue)), no el del servicio.
- Secretos: usa valores de sandbox, no de producción. Límites conocidos:
  - El Developer corre como el mismo usuario del sistema que el servicio y con Bash puede
    leer sus archivos (incluido el archivo de entorno del servicio, con la clave) y
    `/proc/<pid>/environ` de sus procesos.
  - Los checks pueden escribir los secretos en el worktree (p. ej. un `.env` generado).
  - Claude Code guarda transcripciones en el `HOME` del usuario, que pueden contener lo
    que el Developer vio.
  - El filtro y la revisión del push buscan el valor literal (y su forma escapada en
    JSON, y cada línea larga de uno multilínea): no reconocen valores transformados
    (base64, URL-encoded, troceados).

## Despliegue

`bin/deploy` hace pull, compila la release, migra y reinicia el servicio systemd, con las
variables del archivo de entorno (`/etc/factory/factory.env` por defecto,
`FACTORY_ENV_FILE` para otro).

- **`FACTORY_SECRETS_KEY`**: la clave que cifra los secretos de los proyectos, 32 bytes
  en base64. Genérala con `openssl rand -base64 32` y añádela al archivo de entorno.
  - Si falta, la factory arranca, lo avisa en el log (y `bin/deploy` al desplegar) y
    funciona sin secretos: la sección Secrets no deja añadir ni reemplazar, y los
    proyectos que ya tienen secretos fallan al correr una etapa.
  - Si está pero no son 32 bytes en base64, la factory no arranca y dice cómo generarla.
  - Si se pierde o se cambia, los secretos guardados no se pueden recuperar: hay que
    volver a escribirlos en el panel (la lista marca los guardados con otra clave).
- **Entorno mínimo**: checks, agentes, `gh` y `git` no heredan el entorno del servicio
  (`DATABASE_URL`, `SECRET_KEY_BASE`, `MIX_ENV`, `RELEASE_*`…). Solo reciben `PATH HOME
  USER LOGNAME SHELL LANG LANGUAGE TZ TMPDIR SSH_AUTH_SOCK`, los proxies (`HTTP_PROXY`,
  `HTTPS_PROXY`, `NO_PROXY` y sus minúsculas), `SSL_CERT_FILE SSL_CERT_DIR
  CLAUDE_CONFIG_DIR CODEX_HOME GH_CONFIG_DIR`, las que empiezan por `LC_`, `XDG_` o
  `MISE_`, y lo que cada etapa les pasa.
- **`FACTORY_ENV_PASSTHROUGH`**: nombres de variables, separados por comas, que se
  añaden a ese entorno (p. ej. `FACTORY_ENV_PASSTHROUGH=GH_TOKEN,ANTHROPIC_API_KEY`).
  Hace falta si `gh`, `claude` o `codex` se autentican por variables de entorno. Los
  nombres no válidos se ignoran con un aviso al arrancar, y los válidos quedan
  reservados para los secretos. Ojo: el Developer también ve esas variables.

## Configuración adicional

- Issues en paralelo: cola `agents` en `config/config.exs` (2 por defecto).
- Comandos de setup, tests y lint: por proyecto; vacío usa el valor por defecto del
  stack (`lib/factory/stacks.ex`).

## Desarrollo

```sh
mix test        # GitHub, git, checks y agentes se sustituyen por dobles en memoria
mix precommit
```

El código de las etapas está en `lib/factory/pipeline/stages.ex`; los prompts de cada
rol, en `lib/factory/agents/prompts.ex`.
