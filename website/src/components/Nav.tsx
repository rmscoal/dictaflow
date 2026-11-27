import classNames from "classnames";
import { DOWNLOAD_URL, GITHUB_URL } from "../lib/site";
import { WaveformMark } from "./Waveform";
import styles from "./Nav.module.scss";

const LINKS = [
  { label: "Home", href: "#top", active: true },
  { label: "How it works", href: "#how" },
  { label: "Features", href: "#features" },
  { label: "Privacy", href: "#privacy" },
  { label: "FAQ", href: "#faq" },
];

export function Nav() {
  return (
    <header className={styles.nav}>
      <a className={styles.logo} href="#top" aria-label="DictaFlow home">
        <WaveformMark />
        DictaFlow
      </a>

      <nav className={styles.pillNav} aria-label="Primary">
        {LINKS.map((link) => (
          <a
            key={link.label}
            href={link.href}
            className={classNames({ [styles.active]: link.active })}
            aria-current={link.active ? "page" : undefined}
          >
            {link.label}
          </a>
        ))}
      </nav>

      <div className={styles.actions}>
        <a className={styles.github} href={GITHUB_URL} target="_blank" rel="noreferrer">
          GitHub
        </a>
        <a className={styles.download} href={DOWNLOAD_URL} target="_blank" rel="noreferrer">
          Download
        </a>
      </div>
    </header>
  );
}
