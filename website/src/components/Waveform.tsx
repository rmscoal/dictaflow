import classNames from "classnames";
import styles from "./Waveform.module.scss";

const BARS = [7, 12, 18, 12, 7];

export function WaveformMark({ className }: { className?: string }) {
  return (
    <span className={classNames(styles.mark, className)} aria-hidden="true">
      {BARS.map((height, index) => (
        <i key={index} style={{ height }} />
      ))}
    </span>
  );
}

export function WaveformBars({ className }: { className?: string }) {
  return (
    <span className={classNames(styles.bars, className)} aria-hidden="true">
      {Array.from({ length: 12 }, (_, index) => (
        <i key={index} />
      ))}
    </span>
  );
}
