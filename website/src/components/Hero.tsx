import classNames from "classnames";
import { DOWNLOAD_URL } from "../lib/site";
import { WaveformBars } from "./Waveform";
import styles from "./Hero.module.scss";

function Bubble({
  className,
  children,
  avatar = false,
}: {
  className?: string;
  children: React.ReactNode;
  avatar?: boolean;
}) {
  return (
    <div className={classNames(styles.bubble, className)}>
      {avatar ? <span className={styles.avatar} aria-hidden="true" /> : null}
      <span>{children}</span>
    </div>
  );
}

export function Hero() {
  return (
    <>
      <section className={styles.hero}>
        <span className={styles.badge}>
          <b>New</b> DictaFlow 2.7 &nbsp;·&nbsp; Private Dictation for Mac
        </span>
        <h1>
          Private Dictation,
          <br />
          Tailored for You
        </h1>
        <p className={styles.sub}>
          Speak naturally and DictaFlow types polished text into the app you
          are already using. Everything runs on your Mac, without ever
          recording a word in the cloud.
        </p>
        <div className={styles.ctas}>
          <a className={styles.primary} href={DOWNLOAD_URL} target="_blank" rel="noreferrer">
            Download for macOS <span className={styles.arrow}>↗</span>
          </a>
          <a className={styles.secondary} href="#how">
            ▶&nbsp; See how it works
          </a>
        </div>
        <p className={styles.meta}>
          macOS 14+ &nbsp;·&nbsp; Apple silicon &nbsp;·&nbsp; Free &amp; open
          source
        </p>
      </section>

      <section className={styles.stage} aria-label="DictaFlow dictation preview">
        <div className={styles.accessories} aria-hidden="true">
          <span className={styles.ring} />
          <span className={styles.waveStrip}>
            {Array.from({ length: 28 }, (_, index) => (
              <i key={index} />
            ))}
          </span>
          <span className={classNames(styles.chip, styles.chipShortcut)}>
            <kbd>⌘</kbd>
            <kbd>⇧</kbd>
            <kbd>\</kbd> to start
          </span>
          <span className={classNames(styles.chip, styles.chipLocal)}>
            ● On this Mac · No cloud
          </span>
          <span className={classNames(styles.chip, styles.chipTone)}>
            01 Transcribe → 02 Refine → 03 Tone
          </span>
        </div>
        <div className={styles.orbGlow} aria-hidden="true" />
        <Bubble className={styles.bubbleTl} avatar>
          What should I send today?
        </Bubble>
        <Bubble className={styles.bubbleMl}>“Hey um, review the auth PR…”</Bubble>
        <Bubble className={styles.bubbleMr}>Can you clean this up for me?</Bubble>
        <Bubble className={styles.bubbleBr} avatar>
          Done. Inserted into Notes.
        </Bubble>

        <div className={styles.window}>
          <div className={styles.windowBar}>
            <span className={styles.dot} style={{ background: "#FF5F57" }} />
            <span className={styles.dot} style={{ background: "#FEBC2E" }} />
            <span className={styles.dot} style={{ background: "#28C840" }} />
            <span className={styles.windowTitle}>DictaFlow · Dictation</span>
            <span className={styles.onMac}>● On this Mac</span>
          </div>
          <div className={styles.screen}>
            <p className={styles.screenMeta}>9:41 &nbsp;·&nbsp; Whisper Large V3 Turbo</p>
            <div className={styles.orb} aria-hidden="true" />
            <p className={styles.transcript}>
              <span className={styles.dim}>No worries, let me send that for you.</span>
              <br />
              Please review the authentication PR by Wednesday. It may fix the
              login issue.{" "}
              <span className={styles.dim}>Anything else you would like to add?</span>
            </p>
            <div className={styles.bottomBar}>
              <span className={styles.close}>×</span>
              <WaveformBars />
              <span className={styles.stop}>■</span>
            </div>
            <p className={styles.screenFoot}>
              ⌘ ⇧ \ to start &nbsp;·&nbsp; Phi-4-mini refinement &nbsp;·&nbsp;
              Formal tone
            </p>
          </div>
        </div>
      </section>
    </>
  );
}
