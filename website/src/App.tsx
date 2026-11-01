import { Nav } from "./components/Nav";
import { Hero } from "./components/Hero";
import {
  Faq,
  Features,
  FinalCta,
  Footer,
  HowItWorks,
  Privacy,
  RefinementModels,
  SpeechModels,
} from "./components/Sections";
import styles from "./App.module.scss";

export default function App() {
  return (
    <div id="top" className={styles.page}>
      <Nav />
      <main>
        <Hero />
        <Features />
        <HowItWorks />
        <Privacy />
        <SpeechModels />
        <RefinementModels />
        <Faq />
        <FinalCta />
      </main>
      <Footer />
    </div>
  );
}
