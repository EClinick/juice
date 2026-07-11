import { ChargingWordmark } from "./charging-wordmark";

function AppleMark() {
  return <span className="apple-mark" aria-hidden="true">{"\uF8FF"}</span>;
}

export default function Home() {
  return (
    <main>
      <section className="hero" aria-labelledby="hero-title">
        <nav className="nav" aria-label="Primary navigation">
          <a className="brand" href="#top" aria-label="Juice home">
            JUICE<span>®</span>
          </a>
          <a className="github-link" href="https://github.com/EClinick/juice">
            GitHub <span aria-hidden="true">↗</span>
          </a>
        </nav>

        <div className="product-stage" aria-label="MacBook notch">
          <div className="notch" />
        </div>

        <div id="top" className="hero-copy">
          <p className="eyebrow">A battery history for your Mac</p>
          <ChargingWordmark />
          <p className="subtitle">Know where your battery went.</p>
          <a className="download-button" href="https://github.com/EClinick/juice/releases/latest/download/Juice.dmg">
            <AppleMark />
            Download for Mac
          </a>
          <p className="release-note">
            macOS 14+ · Apple silicon and Intel. Free and{" "}
            <a className="release-link" href="https://github.com/EClinick/juice">open source</a>.
          </p>
        </div>

        <a className="maker-link" href="https://x.com/EthanClinick">by Ethan <span aria-hidden="true">↗</span></a>
      </section>
    </main>
  );
}
