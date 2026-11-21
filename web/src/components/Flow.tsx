// A small top-down flowchart: boxes with a title and one short line, joined
// by arrows. Boxes come in two kinds, so a reader can tell at a glance what
// exists today from what the plan would add.

export interface FlowNode {
  id: string;
  x: number;
  y: number;
  width: number;
  title: string;
  detail: string;
  kind: 'existing' | 'added';
}

const HEIGHT = 56;
const WIDTH = 680;

function centre(n: FlowNode) {
  return n.x + n.width / 2;
}

// Straight down when the boxes line up, otherwise down, across, down.
function edgePath(from: FlowNode, to: FlowNode): string {
  const x1 = centre(from);
  const y1 = from.y + HEIGHT;
  const x2 = centre(to);
  const y2 = to.y - 8;
  if (x1 === x2) return `M${x1} ${y1} L${x2} ${y2}`;
  const mid = y1 + (y2 - y1) / 2;
  return `M${x1} ${y1} L${x1} ${mid} L${x2} ${mid} L${x2} ${y2}`;
}

export default function Flow({ nodes, edges, label, legend = true }: {
  nodes: FlowNode[]; edges: [string, string][]; label: string; legend?: boolean;
}) {
  const byId = new Map(nodes.map((n) => [n.id, n]));
  const height = Math.max(...nodes.map((n) => n.y + HEIGHT)) + 16;
  const marker = `arrow-${label.replace(/\W+/g, '-')}`;

  return (
    <figure className="flow">
      <svg viewBox={`0 0 ${WIDTH} ${height}`} role="img" aria-label={label}>
        <defs>
          <marker id={marker} viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6" markerHeight="6" orient="auto">
            <path d="M2 1 8 5 2 9" className="flow-arrowhead" />
          </marker>
        </defs>
        {edges.map(([a, b]) => (
          <path key={`${a}-${b}`} d={edgePath(byId.get(a)!, byId.get(b)!)} className="flow-edge" markerEnd={`url(#${marker})`} />
        ))}
        {nodes.map((n) => (
          <g key={n.id} className={`flow-node ${n.kind}`}>
            <rect x={n.x} y={n.y} width={n.width} height={HEIGHT} rx={8} />
            <text x={centre(n)} y={n.y + 22} textAnchor="middle" className="flow-title">{n.title}</text>
            <text x={centre(n)} y={n.y + 40} textAnchor="middle" className="flow-detail">{n.detail}</text>
          </g>
        ))}
      </svg>
      {legend && (
        <figcaption>
          <span className="flow-key existing" aria-hidden="true" /> Exists today
          <span className="flow-key added" aria-hidden="true" style={{ marginLeft: 16 }} /> What I would add
        </figcaption>
      )}
    </figure>
  );
}
