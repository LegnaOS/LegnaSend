import { svgView } from './svg-view.js';
window.LegnaDiagramRenderer = async ({ cache, container }) => svgView(cache.svg, container);
