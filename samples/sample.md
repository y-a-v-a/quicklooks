---
title: Sample Markdown
tags: [quicklook, markdown]
---

# Markdown sample

Covers every element the previewer styles. Text with **bold**, *italic*,
***both***, ~~strikethrough~~, `inline code` and a [link](https://github.com).
A line ending in two spaces  
breaks without a new paragraph.

## Code

Fix in `@theme inline`: `--font-sans: var(--font-sans)` is circular.

```css
--color-gain: var(--gain);
--color-loss: var(--loss);
```

```swift
// Keywords, strings, numbers and comments, coloured per language.
func greet(_ name: String) -> String {
    let count = 42
    return "Hello, \(name)! \(count)"
}
```

```python
def total(items):  # a comment
    return sum(i.price for i in items if i is not None)
```

```bash
export PATH="$HOME/bin:$PATH"
for f in *.md; do echo "$f"; done
```

```json
{ "name": "quicklooks", "version": 1, "private": true }
```

```
No language tag: plain green.
```

### Lists

- First item
- Second item with `code`
  - Nested item
    - Deeper still
- [ ] Open task
- [x] Done task

1. One
2. Two
   1. Two point one

> A quote, with **bold** inside.
>
> A second paragraph in the same quote.

#### Table

| Left | Center | Right |
|:-----|:------:|------:|
| a    | b      | 1     |
|      | empty  | 22    |
| `x`  | **y**  | 333   |

---

![An image's alt text](picture.png)

<details>raw HTML is shown as source</details>

###### Heading six
