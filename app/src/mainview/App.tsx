import backgroundImage from "@/assets/background.png";
import { electroview } from "@/lib/electrobun";

function App() {
	return (
		<div
			className="electrobun-webkit-app-region-drag fixed inset-0 h-screen w-screen bg-cover bg-center bg-no-repeat"
			style={{ backgroundImage: `url(${backgroundImage})` }}
			onDoubleClick={() => electroview.rpc?.request.toggleMaximizeWindow()}
		/>
	);
}

export default App;
