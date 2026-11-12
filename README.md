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
2. Pon la etiqueta `factory:ready` (configurable) a un issue. La factory lo recoge en
   menos de un minuto.

## Usuarios y permisos

Hay que iniciar sesión para ver cualquier página. La primera vez que abres la factory
(sin usuarios) te pide crear el primer administrador; después nadie puede registrarse
por su cuenta: los usuarios se crean en **Users**, con nombre, apellidos, correo,
contraseña (mínimo 12 caracteres) y un nivel de acceso:

| Nivel | Puede |
| --- | --- |
| Administrator | Todo: proyectos, usuarios y acciones sobre los issues |
| Operator | Aprobar planes, pedir cambios, reintentar y detener issues. No cambia proyectos ni usuarios |
| Read only | Ver todo, sin cambiar nada |

- Cada persona cambia su contraseña en su cuenta (el círculo con sus iniciales).
- Cambiar el nivel, la contraseña o desactivar a alguien cierra todas sus sesiones.
- Siempre debe quedar un administrador activo.
- Las acciones hechas desde el panel quedan con el nombre de quien las hizo. Los
  comentarios en GitHub salen todos con la cuenta de `gh` de la máquina, así que al
  pedir cambios a un plan se añade al comentario quién lo escribió.

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
```

- El Planner clasifica el issue en `easy`, `medium` o `hard`; eso decide el modelo del
  Developer.
- Al agotar las rondas de revisión el issue pasa a `needs_human`. Cada ronda adicional
  la autoriza una persona.
- Si los checks fallan, el Developer lo reintenta (3 intentos; el último con el modelo
  del nivel superior). Si siguen fallando, `needs_human`, sin abrir PR.
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

## Plan en el panel

La página de cada issue muestra `spec.md`, `plan.md` y `tasks.md` en cuanto existen,
leídos de la rama del issue. Mientras el plan espera aprobación puedes aprobarlo ahí
mismo o escribir qué debe cambiar: ese texto se publica en el issue de GitHub como
comentario tuyo y el Planner revisa el plan.

## Comandos en GitHub

En un comentario del issue o del PR, al inicio de una línea:

| Comando | Efecto |
| --- | --- |
| `/factory approve` | Aprueba el plan, o autoriza una ronda más, o reintenta |
| `/factory retry` | Reintenta una etapa fallida |
| `/factory stop` | Detiene el trabajo en el issue |

Cualquier otro comentario mientras se esperan respuestas o la aprobación del plan vuelve
a planificación con ese comentario como contexto. Lo mismo se puede hacer con los
botones de la página del issue.

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
