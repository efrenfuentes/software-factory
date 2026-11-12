# Software Factory

Lleva issues de GitHub hasta un pull request revisado, con agentes de Claude Code:
un **Planner** escribe spec, plan y tareas; un **Reviewer** revisa el plan y luego el PR;
un **Developer** implementa. Un panel web muestra en qué etapa está cada issue, cuánto
tardó en cada una, qué modelo se usó y cuánto costó.

## Requisitos

- Elixir, PostgreSQL
- `gh` autenticado (`gh auth status`) con acceso a los repositorios
- `claude` (Claude Code) autenticado
- Las herramientas del stack de cada repositorio (bundler, mix, cargo, go, npm…)

## Arranque

```sh
mix setup
mix phx.server   # http://localhost:4000
```

1. En **Projects → Add project** elige el repositorio, el tipo de aplicación
   (Rails, Elixir, Rust, Go o Node) y el modelo y esfuerzo de cada rol.
2. Pon la etiqueta `factory:ready` (configurable) a un issue. La factory lo recoge en
   menos de un minuto.

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
