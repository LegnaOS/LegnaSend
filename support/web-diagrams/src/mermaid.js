import mermaid from 'mermaid';
import { svgView } from './svg-view.js';

window.LegnaDiagramRenderer = async function ({ source, cache, dark, container }) {
  let svg;
  if (cache?.kind === 'mermaid' && typeof cache.svg === 'string' && cache.svg.length <= 512 * 1024) {
    svg = cache.svg;
  } else {
    const fixed = {
      startOnLoad: false,
      securityLevel: 'strict',
      suppressErrorRendering: true,
      maxTextSize: 16384,
      maxEdges: 200,
      htmlLabels: false,
      theme: 'base',
      darkMode: dark,
      themeVariables: {
        primaryColor: dark ? '#23462f' : '#e4f4e8',
        primaryTextColor: dark ? '#deebe0' : '#183126',
        primaryBorderColor: '#54b865',
        lineColor: dark ? '#a9c7b1' : '#65836c',
        secondaryColor: dark ? '#293e33' : '#f2f7ee',
        tertiaryColor: dark ? '#1b3023' : '#eff5f1',
        background: dark ? '#17271d' : '#f8fbf8'
      },
      fontFamily: '-apple-system, BlinkMacSystemFont, Segoe UI, sans-serif',
      flowchart: { htmlLabels: false, useMaxWidth: false },
      sequence: { useMaxWidth: false }
    };
    // Diagram frontmatter/directives cannot replace site limits, styles or security.
    fixed.secure = [...new Set(['secure', ...Object.keys(mermaid.mermaidAPI.getConfig()), ...Object.keys(fixed)])];
    mermaid.initialize(fixed);
    svg = (await mermaid.render('legna-diagram', source, container)).svg;
  }
  return svgView(svg, container);
};
