import classNames from "classnames";
import { DOWNLOAD_URL, GITHUB_URL } from "../lib/site";
import { WaveformMark } from "./Waveform";
import openaiLogo from "../assets/providers/openai.svg";
import qwenLogo from "../assets/providers/qwen.svg";
import googleLogo from "../assets/providers/google.svg";
import microsoftLogo from "../assets/providers/microsoft.svg";
import styles from "./Sections.module.scss";

function Tag({ children }: { children: React.ReactNode }) {
  return <span className={styles.tag}>{children}</span>;
}

export function Features() {
  return (
    <section id="features" className={styles.section}>
      <Tag>Features</Tag>
      <h2>Key Advantages of Private Dictation</h2>
      <p className={styles.lead}>
        Instant processing, polished text, and total privacy. No account, no
        upload, no subscription.
      </p>
      <div className={styles.grid3}>
        <article className={styles.card}>
          <h3>Instant processing</h3>
          <p>
            Whisper runs on your Mac with Neural Engine support. Your voice
            never waits on a server.
          </p>
        </article>
        <article className={classNames(styles.card, styles.cardMid)}>
          <h3>Polished before it lands</h3>
          <p>
            Optional on-device refinement, then Formal, Balanced, Casual, or
            Original tone.
          </p>
        </article>
        <article className={styles.card}>
          <h3>Private by design</h3>
          <p>
            Audio, transcripts, and history stay on this Mac. Works fully
            offline after setup.
          </p>
        </article>
      </div>
    </section>
  );
}

const STEPS = [
  {
    title: "Press & speak",
    body: "Hit \u2318 \u21e7 \\ anywhere and talk naturally.",
  },
  {
    title: "Transcribe locally",
    body: "Pick a Whisper model once. It downloads, verifies, and lives on your Mac.",
  },
  {
    title: "Refine & set tone",
    body: "Optional local cleanup gives you ready-to-send text.",
  },
  {
    title: "Inserted for you",
    body: "Text appears at your cursor in Mail, Notes, code, or chat.",
  },
];

export function HowItWorks() {
  return (
    <section id="how" className={classNames(styles.section, styles.alt)}>
      <Tag>How does it work?</Tag>
      <h2>How Your Voice Comes to Life</h2>
      <div className={styles.how}>
        <ol className={styles.steps}>
          {STEPS.map((step, index) => (
            <li key={step.title} className={styles.step}>
              <strong>
                <span className={styles.stepNum}>{String(index + 1).padStart(2, "0")}</span>
                {step.title}
              </strong>
              <p>{step.body}</p>
            </li>
          ))}
        </ol>
        <div className={styles.preview}>
          <p className={styles.previewLabel}>EXAMPLE · BEFORE → AFTER</p>
          <p className={styles.before}>
            “Hey um can you review the auth PR by Wednesday? I think it might
            fix the login issue…”
          </p>
          <p className={styles.after}>
            Please review the authentication PR by Wednesday. It may fix the
            login issue. Testing is still required.
          </p>
          <p className={styles.previewFoot}>Formal tone · Processed on this Mac</p>
        </div>
      </div>
    </section>
  );
}

export function Privacy() {
  return (
    <section id="privacy" className={styles.section}>
      <Tag>Privacy</Tag>
      <h2>Your voice never leaves your Mac.</h2>
      <p className={styles.lead}>
        That is the whole privacy story. Models download once, verify by
        checksum, and stay local. No analytics, no telemetry, no account.
      </p>
      <div className={styles.grid3}>
        <article className={styles.card}>
          <h3>No cloud transcription</h3>
          <p>No server receives your audio or your text. Ever.</p>
        </article>
        <article className={styles.card}>
          <h3>Works offline</h3>
          <p>After setup, dictate on a plane, a train, or anywhere else.</p>
        </article>
        <article className={styles.card}>
          <h3>You control history</h3>
          <p>Keep recordings for 7 days, 14 days, or turn history off.</p>
        </article>
      </div>
    </section>
  );
}

type Model = {
  name: string;
  size: string;
  note: string;
  logo: string;
  provider: string;
};

const SPEECH_MODELS: Model[] = [
  { name: "Tiny", size: "75 MB", note: "Fastest, lightest", logo: openaiLogo, provider: "OpenAI Whisper" },
  { name: "Base", size: "142 MB", note: "Good everyday default", logo: openaiLogo, provider: "OpenAI Whisper" },
  { name: "Small", size: "466 MB", note: "Recommended default", logo: openaiLogo, provider: "OpenAI Whisper" },
  { name: "Medium", size: "1.5 GB", note: "Better accuracy", logo: openaiLogo, provider: "OpenAI Whisper" },
  { name: "Large V3 Turbo", size: "1.5 GB", note: "Best speed and accuracy", logo: openaiLogo, provider: "OpenAI Whisper" },
  { name: "Large V3", size: "2.9 GB", note: "Maximum accuracy", logo: openaiLogo, provider: "OpenAI Whisper" },
];

const REFINEMENT_MODELS: Model[] = [
  { name: "Qwen3 0.6B", size: "0.4 GB", note: "Lightest cleanup, recommended", logo: qwenLogo, provider: "Qwen" },
  { name: "Qwen3.5 2B", size: "1.28 GB", note: "Balanced quality", logo: qwenLogo, provider: "Qwen" },
  { name: "Qwen3-4B-Instruct-2507", size: "2.50 GB", note: "Stronger wording", logo: qwenLogo, provider: "Qwen" },
  { name: "Qwen3.5 4B", size: "2.74 GB", note: "Highest Qwen quality", logo: qwenLogo, provider: "Qwen" },
  { name: "Phi-4-mini Instruct", size: "2.49 GB", note: "Technical and engineering", logo: microsoftLogo, provider: "Microsoft" },
  { name: "Gemma 4 E2B IT QAT", size: "3.35 GB", note: "Largest local model", logo: googleLogo, provider: "Google" },
];

function ModelList({ models }: { models: Model[] }) {
  return (
    <ul className={styles.modelList}>
      {models.map((model) => (
        <li key={model.name} className={styles.modelRow}>
          <span className={styles.modelLogo}>
            <img src={model.logo} alt="" width={22} height={22} />
          </span>
          <span className={styles.modelText}>
            <strong>{model.name}</strong>
            <span>
              {model.provider} · {model.note}
            </span>
          </span>
          <span className={styles.modelSize}>{model.size}</span>
        </li>
      ))}
    </ul>
  );
}

export function SpeechModels() {
  return (
    <section id="models" className={classNames(styles.section, styles.alt)}>
      <Tag>Speech models</Tag>
      <h2>Hear it right, on this Mac.</h2>
      <p className={styles.lead}>
        Whisper turns your voice into text locally. Start small, upgrade only
        if you need to. Every download is checksum-verified before use.
      </p>
      <div className={styles.providerHead}>
        <span className={styles.modelLogo}>
          <img src={openaiLogo} alt="" width={22} height={22} />
        </span>
        <span>
          <strong>Whisper by OpenAI</strong> · runs with whisper.cpp, Neural
          Engine supported
        </span>
      </div>
      <ModelList models={SPEECH_MODELS} />
    </section>
  );
}

export function RefinementModels() {
  return (
    <section id="refinement-models" className={styles.section}>
      <Tag>Text refinement</Tag>
      <h2>Then make it ready to send.</h2>
      <p className={styles.lead}>
        Optional, and also fully local. A small language model cleans
        punctuation and wording before DictaFlow applies your tone. Off by
        default, yours to choose.
      </p>
      <div className={styles.providerRow} aria-label="Refinement providers">
        <span>
          <img src={qwenLogo} alt="" width={18} height={18} /> Qwen
        </span>
        <span>
          <img src={microsoftLogo} alt="" width={18} height={18} /> Microsoft
        </span>
        <span>
          <img src={googleLogo} alt="" width={18} height={18} /> Google
        </span>
      </div>
      <ModelList models={REFINEMENT_MODELS} />
    </section>
  );
}

const FAQS = [
  {
    q: "Is DictaFlow really free?",
    a: "Yes. DictaFlow is free and open source under AGPL-3.0. There is no pricing, account, or subscription.",
  },
  {
    q: "Which Macs are supported?",
    a: "Apple silicon Macs running macOS 14 or newer. After models download, dictation works offline.",
  },
  {
    q: "Which languages can I speak?",
    a: "Whisper is multilingual. Transcribe in your language, or translate supported speech into English.",
  },
  {
    q: "Where does my audio go?",
    a: "Nowhere. Recording, transcription, and optional refinement all happen on your Mac.",
  },
  {
    q: "Does it work in my apps?",
    a: "If you can type there, you can dictate there. DictaFlow inserts at your cursor and restores your clipboard after.",
  },
];

export function Faq() {
  return (
    <section id="faq" className={styles.section}>
      <Tag>FAQ</Tag>
      <h2>Questions, answered</h2>
      <div className={styles.faqList}>
        {FAQS.map((item) => (
          <details key={item.q} className={styles.faqItem}>
            <summary>{item.q}</summary>
            <p>{item.a}</p>
          </details>
        ))}
      </div>
    </section>
  );
}

export function FinalCta() {
  return (
    <section className={styles.final}>
      <h2>Your voice, turned into text.</h2>
      <p className={styles.lead}>Free for Mac. Download once, dictate anywhere.</p>
      <a className={styles.primary} href={DOWNLOAD_URL} target="_blank" rel="noreferrer">
        Download for macOS <span className={styles.arrow}>↗</span>
      </a>
      <p className={styles.meta}>Open source on GitHub · AGPL-3.0 · No account needed</p>
    </section>
  );
}

export function Footer() {
  return (
    <footer className={styles.footer}>
      <a className={styles.footerLogo} href="#top">
        <WaveformMark /> DictaFlow
      </a>
      <nav aria-label="Footer">
        <a href="#how">How it works</a>
        <a href="#features">Features</a>
        <a href="#privacy">Privacy</a>
        <a href={GITHUB_URL} target="_blank" rel="noreferrer">
          GitHub
        </a>
        <a href={DOWNLOAD_URL} target="_blank" rel="noreferrer">
          Releases
        </a>
      </nav>
      <p>Private dictation for Mac. Runs locally with whisper.cpp.</p>
    </footer>
  );
}
