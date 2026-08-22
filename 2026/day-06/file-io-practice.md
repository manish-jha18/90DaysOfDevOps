# Day 06 – Reading and Writing Text Files

The file I created is `notes.txt`, saved in this folder.

## 1. Create an empty file

```
devops@testvm:~$ touch notes.txt

devops@testvm:~$ ls -l notes.txt
-rw-r--r-- 1 devops devops 0 Jun 13 11:02 notes.txt
```

Size is `0`. `touch` only creates the file, it does not put anything inside. If the file already exists, `touch` updates its timestamp instead of wiping it.

---

## 2. Write the first line with `>`

```
devops@testvm:~$ echo "Line 1 - starting my Day 06 file practice" > notes.txt

devops@testvm:~$ cat notes.txt
Line 1 - starting my Day 06 file practice
```

One `>` means overwrite. Whatever was in the file is gone. I tested this by running the same command twice with different text and the first line disappeared. Worth remembering before pointing `>` at a config file.

---

## 3. Append with `>>`

```
devops@testvm:~$ echo "Line 2 - appended with >>" >> notes.txt

devops@testvm:~$ cat notes.txt
Line 1 - starting my Day 06 file practice
Line 2 - appended with >>
```

Two `>>` means add to the end. Line 1 survived this time.

---

## 4. Write and display at once with `tee`

```
devops@testvm:~$ echo "Line 3 - written with tee -a" | tee -a notes.txt
Line 3 - written with tee -a
```

`tee` printed the text to the screen and wrote it to the file in the same step. The `-a` matters — without it, `tee` overwrites the file just like a single `>`.

Where this is useful: piping a long command into `tee` so I can watch the output scroll past and still keep a copy in a log file.

---

## 5. Read the whole file with `cat`

I added a few more lines the same way to reach 8 total, then read it back.

```
devops@testvm:~$ cat notes.txt
Line 1 - starting my Day 06 file practice
Line 2 - appended with >>
Line 3 - written with tee -a
Line 4 - a single > overwrites the whole file
Line 5 - a double >> adds to the end
Line 6 - tee writes to the file and prints at the same time
Line 7 - head reads the top, tail reads the bottom
Line 8 - end of practice
```

---

## 6. Read parts with `head` and `tail`

```
devops@testvm:~$ head -n 2 notes.txt
Line 1 - starting my Day 06 file practice
Line 2 - appended with >>

devops@testvm:~$ tail -n 2 notes.txt
Line 7 - head reads the top, tail reads the bottom
Line 8 - end of practice
```

`head` reads from the top, `tail` reads from the bottom. With no `-n` they both default to 10 lines.

---

## 7. Sanity check

```
devops@testvm:~$ wc -l notes.txt
8 notes.txt
```

8 lines, which matches what I expected.

---

## Command summary

| Command | What it does |
|---|---|
| `touch notes.txt` | Create an empty file, or update its timestamp |
| `echo "text" > file` | Write text, overwriting everything |
| `echo "text" >> file` | Write text, appending to the end |
| `echo "text" \| tee -a file` | Append and print to screen |
| `cat file` | Show the whole file |
| `head -n 2 file` | Show the first 2 lines |
| `tail -n 2 file` | Show the last 2 lines |
| `wc -l file` | Count the lines |

---

## What I learned today

- `>` and `>>` are the pair to be careful with. One arrow wipes the file, two arrows add to it.
- `tail` is the one I will use most in real work, because logs are read from the bottom.
- `tee` is the answer when I want to see the output and save it at the same time.
- `touch` on an existing file is safe and does not erase anything.
