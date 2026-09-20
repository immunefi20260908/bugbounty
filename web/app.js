const projects = [
  {
    title: 'Immunefi Lab',
    category: 'security',
    summary: 'DeFi の再入攻撃、フラッシュローン、JPYC の資金フローを再現する Solidity セキュリティラボです。',
    detail: 'Foundry の9テストで、正常系・境界値・攻撃系を検証。脆弱な状態更新順をコードコメントとトレースで説明しています。',
    stack: ['Solidity', 'Foundry', 'JPYC Mock'],
    accent: 'Audit-first'
  },
  {
    title: 'Vault Reentrancy Demo',
    category: 'security',
    summary: '再入攻撃で資金が複数回引き出される流れを再現し、対策の重要性を視覚的に伝えるデモです。',
    detail: 'ロジックの構造と状態更新順を確認しながら、改修に必要な安全策とテスト観点を整理しました。',
    stack: ['Solidity', 'Testing', 'Security'],
    accent: 'Threat modeling'
  },
  {
    title: 'Portfolio Web App',
    category: 'frontend',
    summary: '採用担当者向けに技術力と価値観が伝わる情報設計とデザインを意識したポートフォリオサイトです。',
    detail: '要点を見せる構成、明確な自己PR、プロジェクトの魅力を伝える UI を考えました。',
    stack: ['JavaScript', 'HTML', 'CSS'],
    accent: 'UX + Storytelling'
  }
];

const projectGrid = document.querySelector('#projectGrid');
const filterButtons = document.querySelectorAll('.filter-btn');
const copyButton = document.querySelector('.copy-btn');
const yearNode = document.querySelector('#year');

if (yearNode) {
  yearNode.textContent = new Date().getFullYear();
}

function renderProjects(filter = 'all') {
  const visibleProjects = filter === 'all' ? projects : projects.filter((project) => project.category === filter);

  projectGrid.innerHTML = visibleProjects
    .map(
      (project) => `
        <article class="project-card">
          <div class="project-header">
            <span class="project-tag">${project.accent}</span>
            <span class="project-type">${project.category === 'security' ? 'Security' : 'Frontend'}</span>
          </div>
          <h3>${project.title}</h3>
          <p>${project.summary}</p>
          <div class="project-detail">${project.detail}</div>
          <div class="stack-row">
            ${project.stack.map((item) => `<span>${item}</span>`).join('')}
          </div>
        </article>
      `
    )
    .join('');
}

filterButtons.forEach((button) => {
  button.addEventListener('click', () => {
    filterButtons.forEach((item) => item.classList.remove('is-active'));
    button.classList.add('is-active');
    renderProjects(button.dataset.filter);
  });
});

if (copyButton) {
  copyButton.addEventListener('click', async () => {
    const email = 'sora.kato.dev@example.com';

    try {
      await navigator.clipboard.writeText(email);
      copyButton.textContent = 'Copied!';
      setTimeout(() => {
        copyButton.textContent = 'Copy Email';
      }, 1600);
    } catch (error) {
      copyButton.textContent = 'Copy failed';
      setTimeout(() => {
        copyButton.textContent = 'Copy Email';
      }, 1600);
    }
  });
}

renderProjects();
