# Day 38 – YAML Basics

Both YAML files are in this folder. I have already written a fair amount of YAML in the Docker Compose days, but never sat down with the rules, so this filled in gaps I did not know I had.

---

## Task 1 and 2: Key-value pairs and lists

**`person.yaml`**

```yaml
name: Manish Jha
role: DevOps Learner
experience_years: 3
learning: true

tools:
  - Linux
  - Git
  - Docker
  - Docker Compose
  - GitHub Actions

hobbies: [reading, cricket, cooking]

learning_as_string: "true"
version_unquoted: 1.20
version_quoted: "1.20"
```

Parsed to JSON to see exactly what YAML produced:

```
devops@testvm:~/day-38$ npx js-yaml person.yaml
{
  "name": "Manish Jha",
  "role": "DevOps Learner",
  "experience_years": 3,
  "learning": true,
  "tools": [
    "Linux",
    "Git",
    "Docker",
    "Docker Compose",
    "GitHub Actions"
  ],
  "hobbies": [
    "reading",
    "cricket",
    "cooking"
  ],
  "learning_as_string": "true",
  "version_unquoted": 1.2,
  "version_quoted": "1.20"
}
```

Types are inferred without being declared: `3` is a number, `true` is a boolean, `"true"` in quotes is a string.

**The interesting one is `version_unquoted: 1.20`, which came out as `1.2`.** YAML read it as a float, and a float has no trailing zero. If that were an image tag or a version constraint, the value would be silently wrong. `"1.20"` in quotes survives intact.

### Two ways to write a list

**Block style** — one item per line, each prefixed with `- `:

```yaml
tools:
  - Linux
  - Git
```

**Flow style** — inline, square brackets, like JSON:

```yaml
hobbies: [reading, cricket, cooking]
```

Identical to the parser. Block style for anything long or likely to change, because the diff stays readable — adding one item is a one-line change rather than a rewrite of the whole line. Flow style for short fixed lists, which is why GitHub Actions files are full of `branches: [main]`.

---

## Task 3: Nested objects

**`server.yaml`**

```yaml
server:
  name: devboard-app
  ip: 10.0.2.15
  port: 8080

database:
  host: postgres
  name: devboard
  credentials:
    user: devboard
    password: devboard
```

```
devops@testvm:~/day-38$ npx js-yaml server.yaml
{
  "server": {
    "name": "devboard-app",
    "ip": "10.0.2.15",
    "port": 8080
  },
  "database": {
    "host": "postgres",
    "name": "devboard",
    "credentials": {
      "user": "devboard",
      "password": "devboard"
    }
  },
  ...
}
```

Indentation is the only thing creating structure. There are no braces and no closing tags — two spaces deeper means "inside the thing above".

`10.0.2.15` came out as a **string**, not a number, because it has more than one dot. `port: 8080` is a number. Nothing declares this; YAML guesses from the shape of the value.

### Trying a tab

```
devops@testvm:~/day-38$ cat -A tab-test.yaml
server:$
^Iname: broken$
^Iport: 8080$

devops@testvm:~/day-38$ npx js-yaml tab-test.yaml
YAMLException: tab characters must not be used in indentation (2:1)

 1 | server:
 2 | →name: broken
-----^
 3 | →port: 8080
```

A clear error with a line number and an arrow. **Tabs are forbidden in YAML indentation**, full stop. The parser is helpful here, but the editor is not — a tab and two spaces look identical on screen. `cat -A` shows tabs as `^I`, which is how to check.

Every editor I use is now set to convert tabs to spaces for `.yml` and `.yaml`.

---

## Task 4: Multi-line strings

```yaml
startup_script: |
  #!/bin/bash
  set -euo pipefail
  echo "starting devboard"
  docker compose up -d
  curl -sf http://localhost:8080/health

description: >
  DevBoard is a three tier demo application
  with a React frontend, a Go API and a
  Postgres database, all running in containers.
```

What each produced:

```json
"startup_script": "#!/bin/bash\nset -euo pipefail\necho \"starting devboard\"\ndocker compose up -d\ncurl -sf http://localhost:8080/health\n"

"description": "DevBoard is a three tier demo application with a React frontend, a Go API and a Postgres database, all running in containers.\n"
```

**`|` keeps the newlines.** Every `\n` is preserved exactly as written.

**`>` folds them into spaces.** Three lines became one, joined with single spaces.

### When to use which

**`|` (literal)** for anything where line breaks are meaningful — shell scripts, config file contents, formatted output. A script folded onto one line would be a syntax error, so this is not a style preference.

**`>` (folded)** for long prose that only wraps for readability in the source file. Descriptions, commit message templates, documentation strings.

**In GitHub Actions this matters constantly**, because a multi-line `run:` is always `|`:

```yaml
- name: Build and test
  run: |
    npm install
    npm run lint
    npm test
```

With `>` that becomes `npm install npm run lint npm test` on one line — a nonsense command. Getting this wrong produces a confusing failure, because the YAML is valid and the shell command is not.

Both forms keep a single trailing newline by default. `|-` and `>-` strip it, `|+` and `>+` keep all of them.

---

## Task 5: Validating

I used `js-yaml` through `npx` rather than installing `yamllint`, since Node was already on the machine:

```
devops@testvm:~/day-38$ npx js-yaml person.yaml
devops@testvm:~/day-38$ npx js-yaml server.yaml
```

Both parsed cleanly. Printing the resulting JSON is more useful than a plain pass/fail, because it shows the **types** — that is how I caught `1.20` turning into `1.2`.

Breaking the indentation on purpose:

```
devops@testvm:~/day-38$ npx js-yaml broken-indent.yaml
YAMLException: bad indentation of a mapping entry (4:3)

 2 |   name: devboard-app
 3 |     ip: 10.0.2.15
 4 |   port: 8080
--------^
```

Line and column, with a caret at the offending character. Fixed the indentation and it parsed.

`yamllint` is the stricter option and worth having in CI. It goes beyond "is this parseable" and flags trailing whitespace, over-long lines, inconsistent indentation and duplicate keys:

```bash
pip install yamllint
yamllint person.yaml server.yaml
```

---

## Task 6: Spot the difference

```yaml
# Block 1 - correct
name: devops
tools:
  - docker
  - kubernetes
```

```yaml
# Block 2 - broken
name: devops
tools:
- docker
  - kubernetes
```

I expected block 2 to throw an error. It does not.

```
devops@testvm:~/day-38$ npx js-yaml block2.yaml
{
  "name": "devops",
  "tools": [
    "docker - kubernetes"
  ]
}
```

**One item, containing the literal string `"docker - kubernetes"`.**

Against the correct version:

```
devops@testvm:~/day-38$ npx js-yaml block1.yaml
{
  "name": "devops",
  "tools": [
    "docker",
    "kubernetes"
  ]
}
```

Two items, as intended.

**What is actually wrong:** the `- docker` entry starts a list item, and because the next line is indented *further* than that item, YAML treats it as a continuation of the same scalar value rather than a new item. Multi-line plain scalars get folded together with a space, so `docker` and `- kubernetes` become one string.

`tools:` with no indentation on its items is legal on its own — this is valid:

```yaml
tools:
- docker
- kubernetes
```

The bug is the **inconsistency** between the two items, not the lack of indentation.

**This is the important lesson of the day.** A YAML mistake that throws an error is easy — the parser tells you the line. A YAML mistake that parses into the *wrong structure* gives you no error at all, and you find out when the pipeline behaves strangely. Printing the parsed output is the only reliable way to check that YAML means what you think it means.

---

## Files in this folder

| File | What it demonstrates |
|---|---|
| `person.yaml` | Key-value pairs, both list styles, type inference and quoting |
| `server.yaml` | Nested objects, `\|` literal and `>` folded blocks |

---

## What I learned

**1. Invalid YAML errors loudly; wrong YAML does not.** Block 2 parsed happily into `"docker - kubernetes"` — one string instead of two items. The parser was satisfied and the meaning was wrong. Since then I check YAML by printing the parsed structure, not by checking it parses.

**2. Quoting is about types, not about style.** `1.20` becomes the float `1.2` and loses its trailing zero. `true` is a boolean and `"true"` is a string. For anything that is really a label — a version, an image tag, a port written as text — quote it.

**3. `|` and `>` are not interchangeable.** Literal keeps newlines, folded turns them into spaces. In GitHub Actions a multi-line `run:` must be `|`, or the three commands you wrote become one impossible command.

**Two extras:**

- Tabs are illegal in YAML indentation and look identical to spaces in an editor. `cat -A` reveals them as `^I`.
- IP addresses parse as strings because they contain more than one dot, while a port parses as a number. Nothing declares this — YAML infers types from the shape of the value.
