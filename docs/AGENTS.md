# Larynx with your AI tools

Typing a long prompt is slow. Saying it is fast, and you think better out loud. Larynx is built for that: hold your
talk key, say what you want the way you'd explain it to a colleague, let go, and the text is in the prompt box.
Nothing is sent anywhere; the speech model runs on your Mac.

There are three ways in, from no setup at all to scripting:

1. **Dictate into the agent**, in any app. Nothing to set up.
2. **Give the agent Larynx as a tool** with the MCP server, so it can transcribe audio files and clean up text itself.
3. **Script it** with the command line or the JSON-lines API.

## 1. Dictate into coding agents and terminals

Larynx picks how much to polish from the app in front. In these apps it uses the **AI mode**: fillers, stutters and
false starts are taken out, but no period is added and the on-device AI rewrite never runs, because the model reading
your prompt doesn't need polish and waiting for it would only slow you down.

| Kind | Apps |
| --- | --- |
| AI chats | Claude, ChatGPT |
| Editors | Cursor, VS Code, Zed, Xcode |
| Terminals | Terminal, iTerm2, Warp, Ghostty |

Say this:

> um so can you uh refactor the the login function so it it returns early

and this is what lands in the prompt:

> So can you refactor the login function so it returns early

Things worth knowing:

- **Larynx never presses Return.** It pastes and stops, so a command in a terminal never runs and a prompt is never
  sent until you press the key yourself. Read it, then send it.
- **Think out loud.** "Um"s, stutters and repeated words are removed, so you can talk the way you think, with no need
  to plan the sentence first. Agents are good at reading a spoken prompt, change of mind included.
- **Teach it your stack.** If it keeps writing "cube control" for kubectl, choose Edit Dictionary... in the menu (or use the
  MCP tool below) and add it once. Words you correct by saying them again are learned on their own.
- **Lost a prompt?** Every dictation is kept on your Mac for 30 days. History… (⌘Y) finds it, or from a terminal:
  `larynx history --search refactor`.
- **It's fast.** A typical dictation is transcribed in about 50 milliseconds after you let go (see
  [BENCHMARKS.md](BENCHMARKS.md)), so the text is there by the time your hand is back on the mouse.

Your app is missing from the table? Its text is still cleaned up, just as for any other app (tidied, capitalized).
Open an issue with the app's name and we'll add it.

## 2. The MCP server

`larynx mcp` is a [Model Context Protocol](https://modelcontextprotocol.io) server over stdio. It gives an agent four
tools:

| Tool | What the agent can do with it |
| --- | --- |
| `transcribe_file` | Turn an audio file (voice memo, meeting recording, wav, m4a, mp3, aiff) into clean text, on your Mac |
| `clean_text` | Clean up text that was spoken: fillers, stutters, your dictionary, spoken numbers. Optional `mode` (`ai`, `correspondence`, `standard`, `email`) and `style` (`casual`, `professional`) |
| `add_dictionary_word` | Teach Larynx a word it mishears, such as "cube control" written as "kubectl" |
| `status` | Which speech model is in use, whether the on-device rewrite is available, how many dictionary words you have |

The server uses the installed app's speech model, so it downloads nothing new. It never writes your dictation
history and never uses the microphone.

**Claude Code**, after installing the app:

```bash
claude mcp add larynx -- ~/Applications/Larynx.app/Contents/MacOS/larynx mcp
```

**Other clients** (Claude Desktop, Cursor and most others) take the same command in their JSON settings:

```json
{
  "mcpServers": {
    "larynx": {
      "command": "/Users/YOU/Applications/Larynx.app/Contents/MacOS/larynx",
      "args": ["mcp"]
    }
  }
}
```

Replace `YOU` with your user name (`echo $HOME` prints the whole path). Then ask the agent things like:

- "Transcribe ~/Desktop/standup.m4a and turn it into a list of tasks."
- "Clean up this voice note in the professional style and draft it as an email."
- "Larynx keeps writing 'post gress' for Postgres. Fix that."

The first `transcribe_file` loads the speech model, which takes a few seconds; after that each file takes a fraction
of its length.

## 3. Scripts and apps

The app's binary is also the command-line tool. Put it on your path once:

```bash
echo 'alias larynx="$HOME/Applications/Larynx.app/Contents/MacOS/larynx"' >> ~/.zshrc && source ~/.zshrc
```

Then:

```bash
larynx transcribe memo.m4a                       # print a transcript
larynx transcribe memo.m4a --mode ai             # the same, polished for a prompt
larynx tidy --mode ai "um so the the build is uh failing"
larynx tidy --style professional "yeah so we're gonna ship it friday you know"
larynx history --json --limit 20 | jq -r '.[].text'   # your last 20 dictations
```

Building from source instead? The same commands are at `.build/release/larynx` after `swift build -c release`.

For an app that wants dictation of its own (start, stop, result, with no permission prompts beyond the microphone),
`larynx serve` speaks JSON lines on stdin and stdout. The protocol, a Node example and the result fields are in
[INTEGRATION.md](INTEGRATION.md).

## Checked by a test

`python3 tests/agents.py` runs the examples on this page against the real binary: the AI mode output, the four MCP
tools, a dictionary word added and used at once, the professional style, and a check that your own dictionary is not
touched (the test uses a throwaway folder). `python3 tests/protocol.py` transcribes a file through `serve` and MCP.
