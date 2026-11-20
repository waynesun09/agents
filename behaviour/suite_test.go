//go:build behaviour

package behaviour_test

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/fullsend-ai/fullsend/pkg/behaviourtest"
)

func TestBehaviour(t *testing.T) {
	_, sourceFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("finding behaviour suite source path")
	}

	root := filepath.Dir(sourceFile)
	behaviourtest.RunSuite(t, behaviourtest.SuiteOptions{
		FeaturePaths: featurePaths(root),
		FixturesRoot: "behaviour",
	})
}

// featurePaths is every feature, or the space-separated godog paths in
// BEHAVIOUR_FEATURES (relative to this directory, e.g. "features/fix.feature"
// or "features/triage.feature:3"), so CI can split the suite into shards.
func featurePaths(root string) []string {
	paths := strings.Fields(os.Getenv("BEHAVIOUR_FEATURES"))
	if len(paths) == 0 {
		return []string{filepath.Join(root, "features")}
	}
	for i, p := range paths {
		paths[i] = filepath.Join(root, p)
	}
	return paths
}
