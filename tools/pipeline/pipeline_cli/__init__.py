"""Implementation of the `tools/pipeline/pipeline.py` command-line tool.

The entry point is deliberately the only executable file in this tree. Everything
here is an importable module, which is what lets the test files sit beside it and
`import pipeline_cli` instead of loading their subject through importlib.

Nothing is re-exported from this package on purpose: `from pipeline_cli import
board` says where the code lives, and a flat namespace here would hide that.
"""
